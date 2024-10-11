defmodule NervesWfbNg.BundlexProject do
  use Bundlex.Project

  def project() do
    [
      natives: natives(),
      libs: libs()
    ]
  end

  defp natives() do
    [
      wfb_tx: [
        sources: ["tx.cpp"],
        language: :cpp,
        compiler_flags: ["-std=gnu++11", "-fno-strict-aliasing", "-DWFB_VERSION=\'\"24.8.17.79622-8c81d238\"\'"],
        linker_flags: ["-lrt", "-lsodium"],
        deps: [nerves_wfb_ng: :fec, nerves_wfb_ng: :wifibroadcast],
        interface: :port,
      ],
      wfb_rx: [
        sources: ["rx.cpp"],
        language: :cpp,
        compiler_flags: ["-std=gnu++11", "-fno-strict-aliasing", "-DWFB_VERSION=\'\"24.8.17.79622-8c81d238\"\'"],
        linker_flags: ["-lrt", "-lsodium", "-lpcap"],
        deps: [nerves_wfb_ng: :radiotap, nerves_wfb_ng: :fec, nerves_wfb_ng: :wifibroadcast],
        interface: :port,
      ],
      wfb_keygen: [
        sources: ["keygen.c"],
        language: :cpp,
        compiler_flags: ["-std=gnu99", "-fno-strict-aliasing", "-DWFB_VERSION=\'\"24.8.17.79622-8c81d238\"\'"],
        linker_flags: ["-lrt", "-lsodium", ""],
        interface: :port,
      ],
      wfb_tx_cmd: [
        sources: ["tx_cmd.c"],
        language: :cpp,
        compiler_flags: ["-std=gnu99", "-fno-strict-aliasing", "-DWFB_VERSION=\'\"24.8.17.79622-8c81d238\"\'"],
        linker_flags: ["-lrt", "-lsodium", ""],
        interface: :port,
      ]
    ]
  end

  defp libs() do
    [
      fec: [
        sources: ["fec.c"],
        language: :c,
        compiler_flags: ["-std=gnu99", "-fno-strict-aliasing", "-DWFB_VERSION=\'\"24.8.17.79622-8c81d238\"\'"],
        linker_flags: ["-lrt", "-lsodium"],
        interface: nil,
      ],
      radiotap: [
        sources: ["radiotap.c"],
        language: :c,
        compiler_flags: ["-std=gnu99", "-fno-strict-aliasing", "-DWFB_VERSION=\'\"24.8.17.79622-8c81d238\"\'"],
        linker_flags: ["-lrt", "-lsodium"],
        interface: nil,
      ],
      wifibroadcast: [
        sources: ["wifibroadcast.cpp"],
        language: :cpp,
        compiler_flags: ["-std=gnu++11", "-fno-strict-aliasing", "-DWFB_VERSION=\'\"24.8.17.79622-8c81d238\"\'"],
        linker_flags: ["-lrt", "-lsodium"],
        interface: nil,
      ]
    ]
  end
end
