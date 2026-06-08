#!/usr/bin/env bash
# Standalone Vulkan quantized matrix multiply correctness verifier.

set -euo pipefail

ROWS=128
COLS=128
KDIM=1024
PASSES=4
KEEP_TMP=0

usage() {
	cat <<EOF
Usage: ./scripts/bc250-quant-matmul-verify.sh [--rows N] [--cols N] [--k N] [--passes N] [--keep-tmp]

Runs a Vulkan q4-style packed-weight matrix multiply and compares every output
element with a CPU reference. No model files are required.

Defaults:
  rows=$ROWS cols=$COLS k=$KDIM passes=$PASSES
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--rows)
			ROWS="${2:?missing value for --rows}"
			shift 2
			;;
		--cols)
			COLS="${2:?missing value for --cols}"
			shift 2
			;;
		--k)
			KDIM="${2:?missing value for --k}"
			shift 2
			;;
		--passes)
			PASSES="${2:?missing value for --passes}"
			shift 2
			;;
		--keep-tmp)
			KEEP_TMP=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "ERROR: unknown argument: $1" >&2
			usage >&2
			exit 2
			;;
	esac
done

case "$ROWS:$COLS:$KDIM:$PASSES" in
	*[!0-9:]*|"")
		echo "ERROR: dimensions and passes must be positive integers" >&2
		exit 2
		;;
esac

if [ "$ROWS" -le 0 ] || [ "$COLS" -le 0 ] || [ "$KDIM" -le 0 ] || [ "$PASSES" -le 0 ]; then
	echo "ERROR: dimensions and passes must be positive integers" >&2
	exit 2
fi
if [ $((KDIM % 8)) -ne 0 ]; then
	echo "ERROR: --k must be a multiple of 8" >&2
	exit 2
fi

command -v glslangValidator >/dev/null 2>&1 || {
	echo "ERROR: glslangValidator not found" >&2
	exit 1
}
command -v gcc >/dev/null 2>&1 || {
	echo "ERROR: gcc not found" >&2
	exit 1
}

setup_vulkan_build_env() {
	local prefix libdir
	local -a prefixes=()

	[ -z "${BC250_VULKAN_PREFIX:-}" ] || prefixes+=("$BC250_VULKAN_PREFIX")
	prefixes+=("$HOME/.local/vulkan/usr" "/usr/local" "/usr")

	for prefix in "${prefixes[@]}"; do
		if [ -f "$prefix/include/vulkan/vulkan.h" ]; then
			export CPATH="$prefix/include${CPATH:+:$CPATH}"
		fi
		for libdir in "$prefix/lib/x86_64-linux-gnu" "$prefix/lib64" "$prefix/lib"; do
			if [ -e "$libdir/libvulkan.so" ]; then
				export LIBRARY_PATH="$libdir${LIBRARY_PATH:+:$LIBRARY_PATH}"
				export LD_LIBRARY_PATH="$libdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
			fi
		done
	done

	for libdir in "$HOME/.local/gcc/usr/lib/x86_64-linux-gnu" "$HOME/.local/gcc/usr/lib64" "$HOME/.local/gcc/usr/lib"; do
		if [ -d "$libdir" ]; then
			export LD_LIBRARY_PATH="$libdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
		fi
	done
}

setup_vulkan_build_env

TMPDIR="$(mktemp -d)"
if [ "$KEEP_TMP" -eq 0 ]; then
	trap 'rm -rf "$TMPDIR"' EXIT
else
	echo "Keeping temporary files in $TMPDIR"
fi

cat >"$TMPDIR/bc250_quant_matmul.comp" <<'GLSL'
#version 450

layout(local_size_x = 16, local_size_y = 16) in;

layout(std430, set = 0, binding = 0) readonly buffer QData {
	uint q[];
};

layout(std430, set = 0, binding = 1) readonly buffer XData {
	float x[];
};

layout(std430, set = 0, binding = 2) readonly buffer ScaleData {
	float scale[];
};

layout(std430, set = 0, binding = 3) writeonly buffer OutData {
	float outv[];
};

layout(push_constant) uniform Params {
	uint rows;
	uint cols;
	uint k;
	uint pass;
} pc;

int unpack_i4(uint packed, uint lane)
{
	int v = int((packed >> (lane * 4u)) & 0x0fu);
	return v >= 8 ? v - 16 : v;
}

void main()
{
	uint col = gl_GlobalInvocationID.x;
	uint row = gl_GlobalInvocationID.y;
	if (row >= pc.rows || col >= pc.cols) {
		return;
	}

	uint q_base = row * (pc.k / 8u);
	float row_scale = scale[row];
	float acc = 0.0;
	for (uint kk = 0u; kk < pc.k; ++kk) {
		uint packed = q[q_base + kk / 8u];
		int qv = unpack_i4(packed, kk & 7u);
		float w = float(qv) * row_scale;
		acc = fma(w, x[kk * pc.cols + col], acc);
	}
	outv[row * pc.cols + col] = acc;
}
GLSL

cat >"$TMPDIR/bc250_quant_matmul.c" <<'C'
#define _POSIX_C_SOURCE 200809L

#include <vulkan/vulkan.h>

#include <inttypes.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define BUFFER_COUNT 4u

#define CHECK(call) do { \
	VkResult _res = (call); \
	if (_res != VK_SUCCESS) { \
		fprintf(stderr, "%s failed: %d at line %d\n", #call, _res, __LINE__); \
		return 1; \
	} \
} while (0)

struct params {
	uint32_t rows;
	uint32_t cols;
	uint32_t k;
	uint32_t pass;
};

static uint32_t hash32(uint32_t x)
{
	x ^= x >> 16;
	x *= 0x7feb352du;
	x ^= x >> 15;
	x *= 0x846ca68bu;
	x ^= x >> 16;
	return x;
}

static int unpack_i4(uint32_t packed, uint32_t lane)
{
	int v = (int)((packed >> (lane * 4u)) & 0x0fu);
	return v >= 8 ? v - 16 : v;
}

static double now_sec(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static uint32_t ceil_div_u32(uint32_t a, uint32_t b)
{
	return (a + b - 1u) / b;
}

static uint32_t find_memory_type(VkPhysicalDevice pd, uint32_t bits,
				 VkMemoryPropertyFlags flags)
{
	VkPhysicalDeviceMemoryProperties props;

	vkGetPhysicalDeviceMemoryProperties(pd, &props);
	for (uint32_t i = 0; i < props.memoryTypeCount; ++i) {
		if ((bits & (1u << i)) &&
		    (props.memoryTypes[i].propertyFlags & flags) == flags)
			return i;
	}
	return UINT32_MAX;
}

static int read_file(const char *path, char **buf, size_t *size)
{
	FILE *f = fopen(path, "rb");
	long len;

	if (!f)
		return 1;
	if (fseek(f, 0, SEEK_END) != 0) {
		fclose(f);
		return 1;
	}
	len = ftell(f);
	if (len <= 0) {
		fclose(f);
		return 1;
	}
	rewind(f);
	*buf = malloc((size_t)len);
	if (!*buf) {
		fclose(f);
		return 1;
	}
	if (fread(*buf, 1, (size_t)len, f) != (size_t)len) {
		fclose(f);
		free(*buf);
		return 1;
	}
	fclose(f);
	*size = (size_t)len;
	return 0;
}

static void fill_inputs(uint32_t rows, uint32_t cols, uint32_t k, uint32_t pass,
			uint32_t *q, float *x, float *scale, float *outv)
{
	uint32_t q_words_per_row = k / 8u;

	for (uint32_t r = 0; r < rows; ++r) {
		scale[r] = 0.020f + (float)(hash32(r ^ (pass * 0x9e3779b9u)) & 0xffu) / 16384.0f;
		for (uint32_t word = 0; word < q_words_per_row; ++word) {
			uint32_t packed = 0;
			for (uint32_t lane = 0; lane < 8; ++lane) {
				uint32_t kk = word * 8u + lane;
				uint32_t h = hash32((r + 1u) * 0x45d9f3bu ^ (kk + 17u) ^ (pass * 0x27d4eb2du));
				int qv = (int)(h & 0x0fu) - 8;
				packed |= ((uint32_t)qv & 0x0fu) << (lane * 4u);
			}
			q[r * q_words_per_row + word] = packed;
		}
	}

	for (uint32_t kk = 0; kk < k; ++kk) {
		for (uint32_t c = 0; c < cols; ++c) {
			uint32_t h = hash32((kk + 3u) * 0x85ebca6bu ^ (c + 11u) ^ (pass * 0xc2b2ae35u));
			x[kk * cols + c] = ((float)(int)(h & 0xffffu) - 32768.0f) / 262144.0f;
		}
	}

	memset(outv, 0, (size_t)rows * cols * sizeof(*outv));
}

static uint64_t check_outputs(uint32_t rows, uint32_t cols, uint32_t k,
			      const uint32_t *q, const float *x,
			      const float *scale, const float *outv)
{
	uint64_t errors = 0;
	uint32_t q_words_per_row = k / 8u;

	for (uint32_t r = 0; r < rows; ++r) {
		for (uint32_t c = 0; c < cols; ++c) {
			float want = 0.0f;
			float got = outv[r * cols + c];
			for (uint32_t kk = 0; kk < k; ++kk) {
				uint32_t packed = q[r * q_words_per_row + kk / 8u];
				float w = (float)unpack_i4(packed, kk & 7u) * scale[r];
				want = fmaf(w, x[kk * cols + c], want);
			}
			float diff = fabsf(got - want);
			float tol = 0.001f + fabsf(want) * 0.0002f;
			if (diff > tol) {
				if (errors < 16) {
					fprintf(stderr,
						"mismatch row=%u col=%u got=%g want=%g diff=%g tol=%g\n",
						r, c, got, want, diff, tol);
				}
				errors++;
			}
		}
	}
	return errors;
}

int main(int argc, char **argv)
{
	const char *spv_path;
	uint32_t rows, cols, k, passes;
	VkApplicationInfo app = {
		.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
		.pApplicationName = "bc250-quant-matmul-verify",
		.apiVersion = VK_API_VERSION_1_1,
	};
	VkInstanceCreateInfo ici = {
		.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
		.pApplicationInfo = &app,
	};
	VkInstance instance;
	VkPhysicalDevice pds[16];
	uint32_t pd_count = 16;
	VkPhysicalDevice pd = VK_NULL_HANDLE;
	VkPhysicalDeviceProperties pd_props;
	VkQueueFamilyProperties qprops[32];
	uint32_t qcount = 32;
	uint32_t queue_family = UINT32_MAX;
	float priority = 1.0f;
	VkDeviceQueueCreateInfo qci = {
		.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
		.queueCount = 1,
		.pQueuePriorities = &priority,
	};
	VkDeviceCreateInfo dci = {
		.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
		.queueCreateInfoCount = 1,
		.pQueueCreateInfos = &qci,
	};
	VkDevice dev;
	VkQueue queue;
	VkBuffer buffers[BUFFER_COUNT] = {0};
	VkDeviceMemory memories[BUFFER_COUNT] = {0};
	void *maps[BUFFER_COUNT] = {0};
	VkDeviceSize sizes[BUFFER_COUNT];
	VkDescriptorSetLayoutBinding bindings[BUFFER_COUNT];
	VkDescriptorSetLayoutCreateInfo dsli = {
		.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		.bindingCount = BUFFER_COUNT,
		.pBindings = bindings,
	};
	VkDescriptorSetLayout dsl;
	VkPushConstantRange pcr = {
		.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
		.offset = 0,
		.size = sizeof(struct params),
	};
	VkPipelineLayoutCreateInfo plci = {
		.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
		.setLayoutCount = 1,
		.pSetLayouts = &dsl,
		.pushConstantRangeCount = 1,
		.pPushConstantRanges = &pcr,
	};
	VkPipelineLayout pipeline_layout;
	char *spv = NULL;
	size_t spv_size = 0;
	VkShaderModuleCreateInfo smci = {
		.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
	};
	VkShaderModule shader;
	VkComputePipelineCreateInfo cpci = {
		.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
	};
	VkPipeline pipeline;
	VkDescriptorPoolSize pool_size = {
		.type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
		.descriptorCount = BUFFER_COUNT,
	};
	VkDescriptorPoolCreateInfo dpci = {
		.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
		.maxSets = 1,
		.poolSizeCount = 1,
		.pPoolSizes = &pool_size,
	};
	VkDescriptorPool pool;
	VkDescriptorSetAllocateInfo dsai = {
		.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
		.descriptorSetCount = 1,
	};
	VkDescriptorSet ds;
	VkCommandPoolCreateInfo cmdp_ci = {
		.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
		.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
	};
	VkCommandPool cmd_pool;
	VkCommandBufferAllocateInfo cbai = {
		.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
		.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
		.commandBufferCount = 1,
	};
	VkCommandBuffer cmd;
	VkFenceCreateInfo fci = {
		.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
	};
	VkFence fence;
	uint64_t total_errors = 0;

	if (argc != 6) {
		fprintf(stderr, "usage: %s shader.spv rows cols k passes\n", argv[0]);
		return 2;
	}
	spv_path = argv[1];
	rows = (uint32_t)strtoul(argv[2], NULL, 0);
	cols = (uint32_t)strtoul(argv[3], NULL, 0);
	k = (uint32_t)strtoul(argv[4], NULL, 0);
	passes = (uint32_t)strtoul(argv[5], NULL, 0);
	if (!rows || !cols || !k || !passes || (k % 8u) != 0) {
		fprintf(stderr, "invalid rows/cols/k/passes\n");
		return 2;
	}

	sizes[0] = (VkDeviceSize)rows * (k / 8u) * sizeof(uint32_t);
	sizes[1] = (VkDeviceSize)k * cols * sizeof(float);
	sizes[2] = (VkDeviceSize)rows * sizeof(float);
	sizes[3] = (VkDeviceSize)rows * cols * sizeof(float);

	CHECK(vkCreateInstance(&ici, NULL, &instance));
	CHECK(vkEnumeratePhysicalDevices(instance, &pd_count, pds));
	for (uint32_t i = 0; i < pd_count; ++i) {
		vkGetPhysicalDeviceProperties(pds[i], &pd_props);
		if (pd_props.vendorID == 0x1002 && strstr(pd_props.deviceName, "BC-250")) {
			pd = pds[i];
			break;
		}
	}
	if (pd == VK_NULL_HANDLE) {
		for (uint32_t i = 0; i < pd_count; ++i) {
			vkGetPhysicalDeviceProperties(pds[i], &pd_props);
			if (pd_props.vendorID == 0x1002) {
				pd = pds[i];
				break;
			}
		}
	}
	if (pd == VK_NULL_HANDLE) {
		fprintf(stderr, "AMD Vulkan device not found\n");
		return 1;
	}

	vkGetPhysicalDeviceProperties(pd, &pd_props);
	vkGetPhysicalDeviceQueueFamilyProperties(pd, &qcount, qprops);
	for (uint32_t i = 0; i < qcount; ++i) {
		if (qprops[i].queueFlags & VK_QUEUE_COMPUTE_BIT) {
			queue_family = i;
			break;
		}
	}
	if (queue_family == UINT32_MAX) {
		fprintf(stderr, "compute queue not found\n");
		return 1;
	}

	qci.queueFamilyIndex = queue_family;
	CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
	vkGetDeviceQueue(dev, queue_family, 0, &queue);

	for (uint32_t i = 0; i < BUFFER_COUNT; ++i) {
		VkBufferCreateInfo bci = {
			.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
			.size = sizes[i],
			.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
			.sharingMode = VK_SHARING_MODE_EXCLUSIVE,
		};
		VkMemoryRequirements req;
		VkMemoryAllocateInfo mai = {
			.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
		};
		uint32_t mem_type;

		CHECK(vkCreateBuffer(dev, &bci, NULL, &buffers[i]));
		vkGetBufferMemoryRequirements(dev, buffers[i], &req);
		mem_type = find_memory_type(pd, req.memoryTypeBits,
					    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT |
					    VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
		if (mem_type == UINT32_MAX) {
			fprintf(stderr, "host visible coherent memory not found\n");
			return 1;
		}
		mai.allocationSize = req.size;
		mai.memoryTypeIndex = mem_type;
		CHECK(vkAllocateMemory(dev, &mai, NULL, &memories[i]));
		CHECK(vkBindBufferMemory(dev, buffers[i], memories[i], 0));
		CHECK(vkMapMemory(dev, memories[i], 0, sizes[i], 0, &maps[i]));
	}

	for (uint32_t i = 0; i < BUFFER_COUNT; ++i) {
		bindings[i].binding = i;
		bindings[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
		bindings[i].descriptorCount = 1;
		bindings[i].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
		bindings[i].pImmutableSamplers = NULL;
	}
	CHECK(vkCreateDescriptorSetLayout(dev, &dsli, NULL, &dsl));
	CHECK(vkCreatePipelineLayout(dev, &plci, NULL, &pipeline_layout));
	if (read_file(spv_path, &spv, &spv_size)) {
		fprintf(stderr, "failed to read SPIR-V shader: %s\n", spv_path);
		return 1;
	}
	smci.codeSize = spv_size;
	smci.pCode = (const uint32_t *)spv;
	CHECK(vkCreateShaderModule(dev, &smci, NULL, &shader));
	cpci.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
	cpci.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
	cpci.stage.module = shader;
	cpci.stage.pName = "main";
	cpci.layout = pipeline_layout;
	CHECK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpci, NULL, &pipeline));

	CHECK(vkCreateDescriptorPool(dev, &dpci, NULL, &pool));
	dsai.descriptorPool = pool;
	dsai.pSetLayouts = &dsl;
	CHECK(vkAllocateDescriptorSets(dev, &dsai, &ds));
	for (uint32_t i = 0; i < BUFFER_COUNT; ++i) {
		VkDescriptorBufferInfo dbi = {
			.buffer = buffers[i],
			.offset = 0,
			.range = sizes[i],
		};
		VkWriteDescriptorSet wds = {
			.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
			.dstSet = ds,
			.dstBinding = i,
			.descriptorCount = 1,
			.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
			.pBufferInfo = &dbi,
		};
		vkUpdateDescriptorSets(dev, 1, &wds, 0, NULL);
	}

	cmdp_ci.queueFamilyIndex = queue_family;
	CHECK(vkCreateCommandPool(dev, &cmdp_ci, NULL, &cmd_pool));
	cbai.commandPool = cmd_pool;
	CHECK(vkAllocateCommandBuffers(dev, &cbai, &cmd));
	CHECK(vkCreateFence(dev, &fci, NULL, &fence));

	printf("device=%s queue_family=%u rows=%u cols=%u k=%u passes=%u\n",
	       pd_props.deviceName, queue_family, rows, cols, k, passes);

	for (uint32_t pass = 0; pass < passes; ++pass) {
		struct params p = {
			.rows = rows,
			.cols = cols,
			.k = k,
			.pass = pass,
		};
		VkCommandBufferBeginInfo cbbi = {
			.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
		};
		VkSubmitInfo si = {
			.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
			.commandBufferCount = 1,
			.pCommandBuffers = &cmd,
		};
		double t0;
		double t1;
		uint64_t errors;

		fill_inputs(rows, cols, k, pass, maps[0], maps[1], maps[2], maps[3]);
		CHECK(vkResetCommandBuffer(cmd, 0));
		CHECK(vkBeginCommandBuffer(cmd, &cbbi));
		vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
		vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE,
					pipeline_layout, 0, 1, &ds, 0, NULL);
		vkCmdPushConstants(cmd, pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT,
				   0, sizeof(p), &p);
		vkCmdDispatch(cmd, ceil_div_u32(cols, 16u), ceil_div_u32(rows, 16u), 1);
		CHECK(vkEndCommandBuffer(cmd));

		CHECK(vkResetFences(dev, 1, &fence));
		t0 = now_sec();
		CHECK(vkQueueSubmit(queue, 1, &si, fence));
		CHECK(vkWaitForFences(dev, 1, &fence, VK_TRUE, UINT64_MAX));
		t1 = now_sec();

		errors = check_outputs(rows, cols, k, maps[0], maps[1], maps[2], maps[3]);
		total_errors += errors;
		printf("pass=%u dispatch_sec=%.6f errors=%" PRIu64 "\n", pass, t1 - t0, errors);
		if (errors)
			break;
	}

	printf("summary rows=%u cols=%u k=%u passes=%u errors=%" PRIu64 "\n",
	       rows, cols, k, passes, total_errors);
	return total_errors ? 1 : 0;
}
C

glslangValidator -V "$TMPDIR/bc250_quant_matmul.comp" -o "$TMPDIR/bc250_quant_matmul.spv" >/dev/null
gcc -std=c11 -O2 -Wall -Wextra -o "$TMPDIR/bc250_quant_matmul" \
	"$TMPDIR/bc250_quant_matmul.c" -lvulkan -lm

"$TMPDIR/bc250_quant_matmul" "$TMPDIR/bc250_quant_matmul.spv" "$ROWS" "$COLS" "$KDIM" "$PASSES"
