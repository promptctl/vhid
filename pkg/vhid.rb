# Written from promptctl/vhid's pkg/vhid.rb at the tag of the release it names, by that
# repository's scripts/update-cask, which fills in the release's version and its pkg's
# sha256. Edit pkg/vhid.rb there; a hand edit here is gone at the next release.
cask "vhid" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/promptctl/vhid/releases/download/v#{version}/vhid-#{version}.pkg"
  name "vhid"
  desc "Virtual keyboard and mouse driven from a CLI or over MCP"
  homepage "https://github.com/promptctl/vhid"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sequoia

  pkg "vhid-#{version}.pkg"

  # vhid-uninstall is the one list of what the pkg installed; it stops the daemon and the
  # menu bar item, removes their files and forgets the receipt. It also deletes itself, vhid
  # and the driver removal, and brew runs zap after uninstall, so the three are copied here,
  # where they outlive that and brew purges them with the rest of the cask. vhid-uninstall
  # finds vhid and the driver removal from where it runs, so the copy keeps /usr/local's layout.
  postflight_steps do
    %w[bin/vhid libexec/vhid-uninstall libexec/vhid-virtual-hid-driver].each do |path|
      copy "/usr/local/#{path}", "kit/#{path}"
    end
  end

  # Leaves the pqrs driver, which Karabiner-Elements may share.
  uninstall script: {
    executable: "#{staged_path}/kit/libexec/vhid-uninstall",
    sudo:       true,
  }

  # The pqrs driver too, refusing as `vhid-uninstall --driver` does.
  zap script: {
    executable: "#{staged_path}/kit/libexec/vhid-uninstall",
    args:       ["--driver"],
    sudo:       true,
  }

  caveats <<~EOS
    macOS lets only the person at the Mac approve a driver. Turn on
    org.pqrs.Karabiner-DriverKit-VirtualHIDDevice under
      System Settings > General > Login Items & Extensions > Driver Extensions (i)
    then run `vhid doctor`; it prints `ready` once vhid can type and click.
  EOS
end
