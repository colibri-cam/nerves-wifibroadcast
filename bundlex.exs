defmodule NervesWifibroadcast.BundlexProject do
  use Bundlex.Project

  def project() do
    [
      natives: natives(),
      libs: libs()
    ]
  end

  defp natives() do
    [
      wfb_crypto: [
        sources: ["wfb_crypto_nif.c"],
        language: :c,
        compiler_flags: [
          "-std=gnu99",
          "-fno-strict-aliasing",
          "-DWFB_VERSION='\"24.8.17.79622-8c81d238\"'"
        ],
        linker_flags: ["-lsodium"],
        interface: :nif
      ],
      wfb_fec: [
        sources: ["wfb_fec_nif.c"],
        language: :c,
        compiler_flags: [
          "-std=gnu99",
          "-fno-strict-aliasing",
          "-DWFB_VERSION='\"24.8.17.79622-8c81d238\"'"
        ],
        deps: [nerves_wifibroadcast: :zfex],
        interface: :nif
      ]
    ]
  end

  defp libs() do
    [
      zfex: [
        sources: ["zfex.c"],
        language: :c,
        compiler_flags: zfex_compiler_flags(),
        linker_flags: [],
        interface: nil
      ]
    ]
  end

  defp zfex_compiler_flags do
    [
      "-std=gnu99",
      "-fno-strict-aliasing",
      "-DZFEX_UNROLL_ADDMUL_SIMD=8",
      "-DZFEX_INLINE_ADDMUL",
      "-DZFEX_INLINE_ADDMUL_SIMD",
      "-DWFB_VERSION='\"24.8.17.79622-8c81d238\"'"
    ] ++ zfex_simd_flags()
  end

  defp zfex_simd_flags do
    arch = Bundlex.get_target().architecture

    cond do
      arch in ["x86_64", "i386", "i686"] ->
        ["-DZFEX_USE_INTEL_SSSE3", "-mssse3"]

      arch in ["aarch64", "arm64"] ->
        ["-DZFEX_USE_ARM_NEON"]

      String.starts_with?(arch, "arm") ->
        ["-DZFEX_USE_ARM_NEON", "-mfpu=neon"]

      true ->
        []
    end
  end
end
