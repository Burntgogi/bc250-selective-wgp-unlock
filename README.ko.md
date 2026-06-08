[한국어](README.ko.md) | [English](README.md)

# BC-250 선택 WGP 언락

AMD BC-250에서 안정적으로 동작하는 추가 WGP만 찾아 활성화하기 위한
스크립트 기반 도구 모음입니다.

BC-250은 기본적으로 24 CU를 노출합니다. 전체 언락 경로는 40 CU를 노출할
수 있지만, 모든 보드가 모든 추가 WGP에서 안정적인 것은 아닙니다. 이
저장소는 coherent mode7 마스킹 흐름을 추가해 불량 extra WGP를 찾고,
반복 검증을 통과한 가장 큰 CU 구성을 사용할 수 있게 합니다.

## 원본 저장소와 감사

이 프로젝트는 원본 공개 작업인
[duggasco/bc250-40cu-unlock](https://github.com/duggasco/bc250-40cu-unlock)을
바탕으로 만들어졌습니다. BC-250 CU 언락 경로를 공개하고 문서화해 준
duggasco 및 원본 기여자들에게 감사드립니다. 이 저장소는 그 작업 위에
선택 WGP 진단, 자동 재부팅 테스트, 모델 파일이 필요 없는 검증 흐름을
추가한 후속 작업입니다.

## 처음 실행할 것

먼저 비파괴 점검 스크립트를 실행합니다.

```bash
./scripts/bc250-doctor.sh
```

그 다음 안내 문서를 따라갑니다.

```bash
less docs/quickstart.md
```

짧은 흐름은 다음과 같습니다.

```bash
# 1. mode7이 아직 없다면 패치된 amdgpu를 빌드합니다.
sudo ./scripts/bc250-enable-40cu.sh build
sudo reboot

# 2. 모델 파일 없이 현재 구성을 검증합니다.
./scripts/bc250-fast-kernel-suite.sh gate

# 3. 추가 WGP를 하나씩 켜며 재부팅 기반으로 테스트합니다.
sudo ./scripts/bc250-wgp-autotest.sh start singles

# 4. baseline으로 돌아온 뒤 결과를 확인합니다.
./scripts/bc250-wgp-autotest.sh report

# 5. single PASS 후보들의 조합을 테스트합니다.
sudo ./scripts/bc250-wgp-autotest.sh start matrix 0.0.4,0.1.4,1.0.4,0.1.3,1.0.3,1.1.3 1

# 6. 가장 좋은 target을 반복 검증하고, 가장 큰 PASS target을 설치합니다.
sudo ./scripts/bc250-wgp-autotest.sh start repeat 0.0.4,0.1.4,1.0.4,0.1.3,1.0.3,1.1.3 10
sudo ./scripts/bc250-wgp-autotest.sh install-recommended
sudo reboot
```

위 WGP 목록은 예시입니다. 실제로는 본인 보드에서 PASS한 후보를 사용해야
합니다.

## 저장소 구성

- `patch/bc250-40cu-amdgpu.patch`: `bc250_cc_write_mode=7` 포함 amdgpu 패치
- `scripts/bc250-enable-40cu.sh`: 패치된 모듈 빌드/설치 helper
- `scripts/bc250-mode7-mask.sh`: coherent mode7 mask 계획/설치
- `scripts/bc250-wgp-autotest.sh`: singles, matrix, repeat 재부팅 자동 테스트
- `scripts/bc250-fast-kernel-suite.sh`: 모델 파일 없는 compute 검증 profile
- `scripts/bc250-quant-matmul-verify.sh`: packed q4-style matrix multiply 검증기
- `scripts/bc250-compute-verify.sh`: Vulkan integer/FP/LDS verifier
- `scripts/bc250-doctor.sh`: 온보딩 및 준비 상태 점검 스크립트

## 안전 모델

- 패치는 BC-250 PCI device ID `0x13FE`에만 동작하도록 제한됩니다.
- module parameter 기본값은 off입니다.
- `bc250_cc_write_mode=7`은 CC, SPI, RLC mask를 일관되게 맞춥니다.
- `baseline`은 mode7 24CU 구성으로 되돌립니다.
- modprobe config를 제거하고 재부팅하면 stock 동작으로 돌아갑니다.

진행 중인 autotest를 중단하고 baseline으로 돌아가려면:

```bash
sudo ./scripts/bc250-wgp-autotest.sh abort
```

BC-250 modprobe config를 제거하려면:

```bash
sudo ./scripts/bc250-mode7-mask.sh disable
sudo reboot
```

## 문서

- [Quickstart](docs/quickstart.md)
- [Selective WGP workflow](docs/selective-wgp-unlock.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Maintainer release checklist](docs/maintainer-release-checklist.md)

## 요구 사항

- BC-250 하드웨어가 있는 Linux 시스템
- 실행 중인 커널과 맞는 kernel headers/source
- `gcc`, `make`, `zstd`, `patch`
- Vulkan runtime, RADV, `vulkaninfo`
- compute verifier 빌드를 위한 `glslangValidator`

## 라이선스

MIT. [LICENSE](LICENSE)를 참고하십시오.
