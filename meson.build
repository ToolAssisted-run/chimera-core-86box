# chimera-core-86box: 86Box, the PC emulator, in miniBox's sandbox, as a
# Chimera core.
#
# Native reference build (run-native and run-wbx):
#     meson setup build/meson-native -Dminibox_dir=<miniBox> && ninja -C build/meson-native
# Guest (core.wbx) build, through the cross file waterbox/setup-guest.sh writes:
#     sh waterbox/setup-guest.sh -m <miniBox> && ninja -C build/meson-guest core.wbx
#
# Upstream builds with CMake and wants SDL or Qt, OpenAL, libslirp,
# libsndfile, FreeType and libpng. None of that is used: the core is built
# twice (host and sandbox) and the two must be the same program, so both are
# built here from one list of upstream's sources (waterbox/sources.py reads
# it from upstream's CMakeLists.txt files and leaves out the user interfaces
# and everything that reaches the host). The platform layer, which upstream
# has one of per user interface, is the core's own: waterbox/chimera-plat.c.
project('chimera-core-86box', 'c', 'cpp',
  default_options: ['c_std=gnu11', 'cpp_std=gnu++17', 'optimization=2', 'debug=false',
                    'warning_level=0', 'b_ndebug=true'])

up = 'extern/86box/src'
py = find_program('python3')

# the submodule pin is upstream as it is; the patches are laid over it
run_command(files('waterbox/apply-patches.sh'), check: true)

mb = get_option('minibox_dir')
if mb == ''
  error('pass -Dminibox_dir=<miniBox checkout>')
endif

src_args = [up]
if get_option('dynarec')
  src_args += '--dynarec'
endif
upstream_sources = []
foreach s : run_command(py, files('waterbox/sources.py'), src_args, check: true).stdout().strip().split('\n')
  upstream_sources += up / s
endforeach

common = [
  '-D_FILE_OFFSET_BITS=64', '-D_LARGEFILE_SOURCE=1', '-D_LARGEFILE64_SOURCE=1',
  '-DRELEASE_BUILD', '-DCHIMERA_CORE',
  # the ESFM synthesizer's C rather than its inline assembly, whose
  # addressing the guest's large code model cannot take: one program in
  # both builds
  '-D_ESFMU_DISABLE_ASM_OPTIMIZATIONS',
  # one thread: 86Box's one thread-local (is_cpu_thread) is a plain variable
  '-D__thread=',
  '-fno-strict-aliasing',
  # one answer from a floating-point expression on every machine
  '-ffp-contract=off', '-msse2', '-mfpmath=sse',
]
if get_option('dynarec')
  common += '-DUSE_DYNAREC'
endif
add_project_arguments(common, language: ['c', 'cpp'])
# 86Box's C files take their random numbers from the core's generator
# (cinterface.c): one sequence in both builds, kept in machine memory
add_project_arguments(['-Drand=chimera_rand', '-Dsrand=chimera_srand'], language: 'c')
inc = [include_directories('waterbox/compat', up / 'include', up / 'cpu')]
if get_option('dynarec')
  inc += include_directories(up / 'codegen')
endif

# position-independent for the native executable; never for the guest,
# which is linked at a fixed address with the large code model
emu = static_library('emu86', upstream_sources, include_directories: inc,
  pic: not meson.is_cross_build())

plat_sources = files('waterbox/chimera-plat.c', 'waterbox/cinterface.c', 'waterbox/chimera-input.c',
  'waterbox/chimera-audio.c',
  up / 'unix/dummy_cdrom_ioctl.c', up / 'unix/dummy_floppy_ioctl.c')

if meson.is_cross_build()
  # ---- the guest: core.wbx --------------------------------------------------
  mbdir = meson.get_external_property('minibox_dir')
  mbuild = meson.get_external_property('minibox_build')
  sr = meson.get_external_property('guest_sysroot')
  executable('core', plat_sources,
    name_suffix: 'wbx',
    include_directories: inc + [include_directories('waterbox')],
    link_whole: emu,
    link_args: [
      '-static', '-no-pie',
      '-Wl,--eh-frame-hdr', '-Wl,-O2', '-Wl,--no-relax',
      '-T', mbdir / 'source/guest/linkscript.T',
      '-Wl,-u,pthread_once', '-Wl,-u,pthread_cond_wait',
      '-Wl,-u,pthread_cond_broadcast', '-Wl,-u,pthread_key_create',
      mbuild / 'source/guest/cxxglue.c.o', mbuild / 'source/guest/emulibc.c.o',
      '-L' + sr / 'lib', '-lstdc++', '-lgcc', '-lgcc_eh', '-lc'])
else
  # ---- the native reference -------------------------------------------------
  m = meson.get_compiler('c').find_library('m', required: false)
  executable('run-native', plat_sources + files('waterbox/run-native.c'),
    include_directories: [include_directories('waterbox/native-shim', 'waterbox')] + inc,
    c_args: ['-I' + mb / 'source/guest/include', '-I' + mb / 'extern/jsmn'],
    link_whole: emu,
    dependencies: [m])

  mbhost = mb / 'build/meson-linux/source/host'
  executable('run-wbx', files('waterbox/run-wbx.c'),
    c_args: ['-I' + mb / 'source/host'],
    link_args: [mbhost / 'libminiboxhost.so'],
    build_rpath: mbhost)
endif
