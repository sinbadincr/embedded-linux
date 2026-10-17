# OTA — Embedded Linux với Buildroot

Repo build image Linux nhúng cho nhiều board bằng [Buildroot](https://buildroot.org), chạy trong
Docker để cả team dùng chung một môi trường build. Board hiện có: **BeagleBone Black**.

## Ý tưởng

| Tầng | Ở đâu | Vai trò |
|---|---|---|
| Buildroot gốc | `buildroot/` (git submodule, nhánh `2026.08.x`) | Code upstream, **không sửa** |
| Phần của dự án | Thư mục gốc repo = cây `BR2_EXTERNAL` tên `OTA` | Defconfig, overlay, script, package, patch |
| Môi trường build | `Dockerfile` | Đủ công cụ host Buildroot cần; mọi lệnh build chạy trong container |

Nâng cấp Buildroot chỉ là đổi commit của submodule; phần của dự án giữ nguyên.

## Cấu trúc

```
ota/
├── Makefile                  # điểm vào: lệnh Docker + chuyển tiếp lệnh sang Buildroot
├── Dockerfile                # môi trường build
├── external.desc             # tên BR2_EXTERNAL: OTA
├── Config.in, external.mk    # nối package/ vào Buildroot
├── buildroot/                # [submodule] Buildroot 2026.08.x
├── configs/
│   └── beaglebone_black_defconfig   # mỗi board/biến thể một file
├── board/ota/
│   ├── common/               # dùng chung cho mọi board
│   │   ├── rootfs_overlay/          # vd. /etc/issue
│   │   └── post-build.sh            # ghi /etc/build-info (board, git version, Buildroot)
│   └── beaglebone_black/     # chỉ riêng BBB
│       ├── rootfs_overlay/          # vd. /etc/hostname
│       ├── post-image.sh            # copy uEnv.txt, extlinux.conf rồi chạy genimage
│       ├── genimage.cfg             # thẻ SD: FAT boot 16M + ext4 rootfs 512M
│       └── uEnv.txt, extlinux.conf
├── package/                  # package nội bộ (khai báo trong package/Config.in)
├── patches/                  # patch + file .hash theo package (linux, uboot, ...)
├── output/<board>/           # [gitignore] kết quả build, mỗi board một thư mục
└── dl/                       # [gitignore] source tải về, dùng chung
```

Trong defconfig, mọi đường dẫn tới repo viết dạng `$(BR2_EXTERNAL_OTA_PATH)/...`. Overlay chung
được chép trước, overlay của board chép sau (trùng file thì bản của board thắng).

## Bắt đầu

Yêu cầu trên host: Git, GNU Make, Docker.

```bash
git clone --recurse-submodules <repo-url> ota    # đã clone rồi: git submodule update --init
cd ota
make docker-build                                 # build image (1 lần, hoặc khi sửa Dockerfile)
```

## Build

```bash
make docker-shell                  # vào container, repo mount tại /workspace

# trong container:
make list-boards                   # các board trong configs/
make beaglebone_black_defconfig    # chọn board (ghi vào .current_board)
make build                         # → output/beaglebone_black/images/sdcard.img
```

Lần build đầu mất khoảng 1 giờ (tải toolchain, kernel, U-Boot); các lần sau nhanh hơn nhiều.

Các lệnh khác (đều chạy trong container, áp dụng cho board đang chọn):

```bash
make menuconfig           # sửa cấu hình Buildroot
make savedefconfig        # ghi lại vào configs/<board>_defconfig → commit file đó
make linux-menuconfig     # sửa cấu hình kernel
make <pkg>-rebuild        # build lại một package
make clean                # xoá output của board
make BOARD=<khác> build   # thao tác với board khác mà không đổi board đang chọn
make help
```

Mọi target không có trong `Makefile` đều được chuyển thẳng sang Buildroot.

## Flash và boot BeagleBone Black

```bash
sudo dd if=output/beaglebone_black/images/sdcard.img of=/dev/sdX bs=4M conv=fsync
```

Giữ nút **S2 (BOOT)** khi cấp nguồn để boot từ thẻ SD. Console UART qua header J1, 115200 8N1.
Đăng nhập `root`, không mật khẩu.

## Mở rộng

**Thêm board mới**
1. Tạo `board/ota/<board>/` (genimage.cfg, post-image.sh, rootfs_overlay/, ...).
2. Tạo `configs/<board>_defconfig`, dùng `$(BR2_EXTERNAL_OTA_PATH)/board/ota/<board>/...` và giữ
   overlay/post-build của `common/`.
3. `make <board>_defconfig && make build` → output riêng ở `output/<board>/`.

**Thêm package nội bộ**: tạo `package/<tên>/Config.in` + `<tên>.mk`, rồi thêm
`source "$BR2_EXTERNAL_OTA_PATH/package/<tên>/Config.in"` vào `package/Config.in`.

**Custom config kernel/U-Boot**: hiện dùng config có sẵn (`omap2plus`, `am335x_evm`). Muốn có
config riêng, đặt `BR2_LINUX_KERNEL_USE_CUSTOM_CONFIG=y` và
`BR2_LINUX_KERNEL_CUSTOM_CONFIG_FILE="$(BR2_EXTERNAL_OTA_PATH)/board/ota/<board>/linux.config"`,
rồi `make linux-update-defconfig` để sinh file (U-Boot tương tự).

**Đổi phiên bản kernel/U-Boot**: defconfig bật `BR2_DOWNLOAD_FORCE_CHECK_HASHES`, nên phải thêm
dòng hash của phiên bản mới vào `patches/linux/linux.hash` hoặc `patches/uboot/uboot.hash`.

**Cập nhật Buildroot**
```bash
git submodule update --remote buildroot   # lấy commit mới nhất của 2026.08.x
# build thử, rồi:
git add buildroot && git commit
```

## Lưu ý

- **Chỉ mount một volume.** Toàn bộ repo mount vào `/workspace`. Không mount riêng `output/` hay
  `dl/`: kconfig dùng `rename()` để ghi cấu hình, khác filesystem sẽ lỗi `EXDEV`
  (`*** Error during update of the configuration.`).
- **Không build bằng root.** Buildroot từ chối chạy dưới root. `make docker-build` tạo user `br`
  cùng UID/GID với bạn, nên file trong `output/` vẫn thuộc về bạn trên host.
- **Thiếu công cụ host** → sửa `Dockerfile` rồi `make docker-build`, không `apt-get` trong
  container đang chạy.
