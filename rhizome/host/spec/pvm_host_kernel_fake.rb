# frozen_string_literal: true

require "fileutils"
require "digest"
require_relative "../../common/lib/util"

# A stand-in Ubuntu 24.04 host for PvmHostKernel specs: files under a
# temporary root, and a runner that plays the commands PvmHostKernel runs
# against that root (grubenv, update-grub, apt marks, dpkg, systemd). It
# logs each command with the root stripped, and fails the commands a spec
# names, so a spec can stop an install after any step and check what
# uninstall leaves behind.
class FakePvmHost
  STOCK = "7.0.0-1014-aws"
  PVM = "6.12.33-pvm"
  PVM_PKG = "linux-image-#{PVM}"
  UUID = "0c0e55d5-9c61-4dfe-9d1a-595531acc3c0"
  CMDLINE_DEFAULT = "console=tty1 console=ttyS0 nvme_core.io_timeout=4294967295"
  DEB_URL = "https://example.com/pvm/linux-image-6.12.33-pvm_amd64.deb"
  DEB_CONTENT = "Package: #{PVM_PKG}\nfake kernel package\n"
  DEB_SHA256 = Digest::SHA256.hexdigest(DEB_CONTENT)

  # The modules a kernel ships: ENA, NVMe and virtio (built in), Xen's
  # front ends, and ext4.
  MODULES = %w[
    kernel/drivers/net/ethernet/amazon/ena/ena.ko.zst
    kernel/drivers/net/xen-netfront.ko.zst
    kernel/drivers/block/xen-blkfront.ko.zst
    kernel/fs/ext4/ext4.ko.zst
  ].freeze
  BUILTIN = %w[
    kernel/drivers/nvme/host/nvme.ko
    kernel/drivers/virtio/virtio_pci.ko
    kernel/drivers/net/virtio_net.ko
    kernel/drivers/block/virtio_blk.ko
  ].freeze

  XEN_DRIVERS = %w[vif vbd].freeze

  attr_reader :root, :log, :held, :auto, :packages, :groups, :enabled
  attr_accessor :kernel, :machine, :container, :avail_kib, :fail_on, :before, :noop, :pvm_modules, :pvm_initrd,
    :rootfs, :device_uuid, :pkg_status

  # submenu: update-grub puts all but the newest kernel under "Advanced
  # options for Ubuntu" (Ubuntu's default). partuuid: a cloud image with
  # GRUB_FORCE_PARTUUID and no initrd for the stock kernel.
  def initialize(root, submenu: true, partuuid: false, stock: STOCK, net: "ena", block: "nvme")
    @root = root
    @stock = stock
    @kernel = stock
    @submenu = submenu
    @partuuid = partuuid
    @log = []
    @held = []
    @auto = ["linux-image-#{stock}"]
    @packages = ["linux-image-#{stock}"]
    @groups = []
    @enabled = []
    @avail_kib = {"/" => 50_000_000}
    @mounts = {}
    @fail_on = []
    @before = []
    @noop = []
    @machine = "x86_64"
    @container = "none"
    @device_uuid = UUID
    @pkg_status = {}
    @pvm_modules = MODULES
    @pvm_initrd = true
    @rootfs = "ext4"
    @urls = {DEB_URL => DEB_CONTENT}
    build(net, block)
  end

  def write(rel, content, mode: 0o644)
    file = File.join(@root, rel)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, content)
    File.chmod(mode, file)
  end

  def read(rel)
    File.read(File.join(@root, rel))
  end

  def exist?(rel)
    File.exist?(File.join(@root, rel))
  end

  # Puts rel on its own file system, mount point "/#{rel}".
  def mount(rel, avail_kib)
    @mounts[rel] = "/#{rel}"
    @avail_kib["/#{rel}"] = avail_kib
  end

  def serve(url, content)
    @urls[url] = content
  end

  def grubenv
    read("boot/grub/grubenv").lines.filter_map { |l| l.chomp.split("=", 2) if l.include?("=") }.to_h
  end

  # Boots kernel k: the cmdline, the loaded modules and grubenv's
  # one-shot next_entry, as GRUB and the kernel would.
  def boot(kver, pti_off: false)
    @kernel = kver
    write("proc/cmdline", "BOOT_IMAGE=/vmlinuz-#{kver} root=UUID=#{UUID} ro #{CMDLINE_DEFAULT}#{" pti=off" if pti_off}\n")
    env = grubenv
    env.delete("next_entry")
    write_grubenv(env)
    if pti_off
      FileUtils.mkdir_p(File.join(@root, "sys/module/kvm_pvm"))
    else
      FileUtils.rm_rf(File.join(@root, "sys/module/kvm_pvm"))
    end
  end

  # Everything uninstall must put back.
  def snapshot
    files = Dir.glob("**/*", File::FNM_DOTMATCH, base: @root).reject { |f| f.start_with?("var/lib/ubicloud") || File.directory?(File.join(@root, f)) }
    {
      "files" => files.sort.to_h { |f| [f, File.symlink?(File.join(@root, f)) ? File.readlink(File.join(@root, f)) : File.read(File.join(@root, f))] },
      "grubenv" => grubenv,
      "held" => @held.sort,
      "auto" => @auto.sort,
      "packages" => @packages.sort,
      "enabled" => @enabled.sort,
    }
  end

  def runner
    method(:call)
  end

  def call(*argv, expect: [0])
    argv = argv.map { |a| a.is_a?(String) ? a.sub(/\A#{Regexp.escape(@root)}/, "") : a }
    @log << argv
    if (hook = @before.find { |m, _| m.call(argv) })
      @before.delete(hook)
      hook.last.call
    end
    if (rule = @fail_on.find { |m| m.call(argv) })
      @fail_on.delete(rule)
      raise CommandFail.new("command failed: #{argv.join(" ")}", "", "injected failure")
    end
    return "" if @noop.any? { |m| m.call(argv) }
    out, status = dispatch(argv)
    raise CommandFail.new("command failed: #{argv.join(" ")}", out, "") unless expect.include?(status)

    out
  end

  # A matcher for fail_on: the command whose words start with words.
  def self.command(*words)
    ->(argv) { strip(argv).first(words.size) == words }
  end

  # The command without env, DEBIAN_FRONTEND and apt's -o Group::Option
  # settings.
  def self.strip(argv)
    argv = argv.drop(2) if argv.first == "env"
    out = []
    argv.each_with_index do |a, i|
      next if a == "-o" && argv[i + 1].to_s.include?("::")
      next if i > 0 && argv[i - 1] == "-o" && a.include?("::")

      out << a
    end
    out
  end

  private

  def dispatch(argv)
    cmd = self.class.strip(argv)
    case cmd
    in ["uname", "-r"] then ["#{@kernel}\n", 0]
    in ["uname", "-m"] then ["#{@machine}\n", 0]
    in ["systemd-detect-virt", "--container"] then ["#{@container}\n", (@container == "none") ? 1 : 0]
    in ["df", "-Pk", dir] then df(dir)
    in ["dpkg-query", "-W", "-f", "${db:Status-Status}", pkg]
      if @pkg_status.key?(pkg) then [@pkg_status[pkg], 0]
      else
        @packages.include?(pkg) ? ["installed", 0] : ["", 1]
      end
    in ["apt-mark", "showhold", pkg] then [@held.include?(pkg) ? "#{pkg}\n" : "", 0]
    in ["apt-mark", "showauto", pkg] then [@auto.include?(pkg) ? "#{pkg}\n" : "", 0]
    in ["apt-mark", "hold", pkg] then mark(@held, pkg, true)
    in ["apt-mark", "unhold", pkg] then mark(@held, pkg, false)
    in ["apt-mark", "auto", pkg] then mark(@auto, pkg, true)
    in ["apt-mark", "manual", pkg] then mark(@auto, pkg, false)
    in ["curl", *, "-o", dest, url] then curl(dest, url)
    in ["dpkg-deb", "-f", deb, "Package"] then [read(deb)[/^Package: (.*)$/, 1] + "\n", 0]
    in ["apt-get", "install", "-y", deb] then apt_install(deb)
    in ["apt-get", "purge", "-y", pkg] then apt_purge(pkg)
    in ["update-grub"] then update_grub
    in ["grub-editenv", "list"] then [grubenv.map { |k, v| "#{k}=#{v}\n" }.join, 0]
    in ["grub-editenv", "-", "unset", key] then edit_env { |env| env.delete(key) }
    in ["grub-set-default", entry] then edit_env { |env| env["saved_entry"] = entry }
    in ["grub-reboot", entry] then edit_env { |env| env["next_entry"] = entry }
    in ["findmnt", "-no", "FSTYPE", "/"] then ["#{@rootfs}\n", 0]
    in ["groupadd", "-f", "-r", group] then mark(@groups, group, true)
    in ["systemctl", "daemon-reload"] then ["", 0]
    in ["systemctl", "enable", unit] then mark(@enabled, unit, true)
    in ["systemctl", "disable", unit] then mark(@enabled, unit, false)
    in ["systemctl", "show", *, unit]
      ["ActiveState=#{(@kernel == @stock) ? "inactive" : "active"}\nResult=success\nUnitFileState=#{@enabled.include?(unit) ? "enabled" : "disabled"}\n", 0]
    in ["stat", "-c", "%a %G", _] then ["660 kvm\n", 0]
    end
  end

  def mark(list, item, on)
    on ? (list << item unless list.include?(item)) : list.delete(item)
    ["", 0]
  end

  def df(dir)
    rel = dir.delete_prefix("/")
    mount = @mounts.find { |r, _| rel == r || rel.start_with?("#{r}/") }&.last || "/"
    ["Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/root 100000000 1 #{@avail_kib.fetch(mount)} 1% #{mount}\n", 0]
  end

  def curl(dest, url)
    return ["curl: (22) The requested URL returned error: 404", 22] unless @urls.key?(url)

    write(dest, @urls[url]) if @urls[url]
    ["", 0]
  end

  def edit_env
    env = grubenv
    yield env
    write_grubenv(env)
    ["", 0]
  end

  def write_grubenv(env)
    write("boot/grub/grubenv", "# GRUB Environment Block\n" + env.map { |k, v| "#{k}=#{v}\n" }.join)
  end

  def install_kernel(kver, modules:, initrd: true)
    write("boot/vmlinuz-#{kver}", "vmlinuz #{kver}\n")
    write("boot/initrd.img-#{kver}", "initrd #{kver}\n") if initrd
    filler = (1..3000).map { |i| "kernel/drivers/filler/filler_module_#{i}.ko.zst: kernel/lib/dep.ko.zst\n" }.join
    write("lib/modules/#{kver}/modules.dep", filler + modules.map { |m| "#{m}:\n" }.join)
    write("lib/modules/#{kver}/modules.builtin", BUILTIN.join("\n") + "\n")
  end

  def apt_install(deb)
    pkg = read(deb)[/^Package: (.*)$/, 1]
    kver = pkg.delete_prefix("linux-image-")
    install_kernel(kver, modules: @pvm_modules, initrd: @pvm_initrd)
    @packages << pkg unless @packages.include?(pkg)
    update_grub
  end

  def apt_purge(pkg)
    kver = pkg.delete_prefix("linux-image-")
    %W[boot/vmlinuz-#{kver} boot/initrd.img-#{kver}].each { |f| FileUtils.rm_f(File.join(@root, f)) }
    FileUtils.rm_rf(File.join(@root, "lib/modules/#{kver}"))
    @packages.delete(pkg)
    @held.delete(pkg)
    update_grub
  end

  def build(net, block)
    write("etc/os-release", "PRETTY_NAME=\"Ubuntu 24.04.3 LTS\"\nVERSION_ID=\"24.04\"\n")
    write("proc/cpuinfo", "processor\t: 0\nflags\t\t: fpu vme de pse tsc msr pae hypervisor lahf_lm\n")
    write("sys/devices/system/cpu/vulnerabilities/meltdown", "Not affected\n")
    write("sys/kernel/security/lockdown", "[none] integrity confidentiality\n")
    write("etc/default/grub", "GRUB_DEFAULT=0\nGRUB_TIMEOUT=0\nGRUB_CMDLINE_LINUX_DEFAULT=\"#{CMDLINE_DEFAULT}\"\nGRUB_CMDLINE_LINUX=\"\"\n#{"GRUB_DISABLE_SUBMENU=y\n" unless @submenu}")
    write("etc/default/grub.d/40-force-partuuid.cfg", "GRUB_FORCE_PARTUUID=#{UUID}\n") if @partuuid
    %w[grub-editenv grub-reboot grub-set-default update-grub].each { |t| write("usr/sbin/#{t}", "", mode: 0o755) }
    %w[curl dpkg-deb].each { |t| write("usr/bin/#{t}", "", mode: 0o755) }
    install_kernel(@stock, modules: MODULES, initrd: !@partuuid)
    write_grubenv({})
    boot(@stock)
    sysfs(net, block)
    update_grub
  end

  # A NIC and a disk behind PCI bridges (pcieport), like an EC2 Nitro
  # instance; or Xen's vif and vbd.
  def sysfs(net, block)
    [["sys/class/net/eth0", net], ["sys/block/xvda", block]].each_with_index do |(cls, driver), i|
      dev = XEN_DRIVERS.include?(driver) ? "sys/devices/vbd-#{i}/#{File.basename(cls)}" : "sys/devices/pci0000:00/0000:00:01.0/0000:0#{i}:00.0"
      FileUtils.mkdir_p(File.join(@root, dev))
      FileUtils.mkdir_p(File.join(@root, "sys/bus/drivers/#{driver}"))
      FileUtils.mkdir_p(File.join(@root, cls))
      File.symlink(File.join(@root, "sys/bus/drivers", driver), File.join(@root, dev, "driver"))
      File.symlink(File.join(@root, dev), File.join(@root, cls, "device"))
    end
    bridge = File.join(@root, "sys/devices/pci0000:00/0000:00:01.0")
    FileUtils.mkdir_p(File.join(@root, "sys/bus/drivers/pcieport"))
    File.symlink(File.join(@root, "sys/bus/drivers/pcieport"), File.join(bridge, "driver")) if File.directory?(bridge)
    FileUtils.mkdir_p(File.join(@root, "sys/class/net/lo"))
  end

  def kernels
    Dir.glob("vmlinuz-*", base: File.join(@root, "boot")).map { |f| f.delete_prefix("vmlinuz-") }
      .sort_by { |k| k.scan(/\d+/).map(&:to_i) }.reverse
  end

  def default_setting
    files = ["etc/default/grub", *Dir.glob("etc/default/grub.d/*.cfg", base: @root).sort]
    files.filter_map { |f| read(f)[/^GRUB_DEFAULT=(\S+)$/, 1] }.last
  end

  # update-grub, with Ubuntu's 00_header and 10_linux, then the scripts
  # in /etc/grub.d: 42_ubicloud_pvm interpreted line by line, and
  # 40_custom appended.
  def update_grub
    default = (default_setting == "saved") ? "${saved_entry}" : "0"
    cfg = <<~CFG
      ### BEGIN /etc/grub.d/00_header ###
      if [ -s $prefix/grubenv ]; then
        set have_grubenv=true
        load_env
      fi
      if [ "${next_entry}" ] ; then
         set default="${next_entry}"
         set next_entry=
         save_env next_entry
         set boot_once=true
      else
         set default="#{default}"
      fi
      ### END /etc/grub.d/00_header ###
      ### BEGIN /etc/grub.d/10_linux ###
    CFG
    ks = kernels
    cfg << "menuentry 'Ubuntu' --class ubuntu $menuentry_id_option 'gnulinux-simple-#{UUID}' {\n#{entry_body(ks.first)}}\n"
    cfg << "submenu 'Advanced options for Ubuntu' $menuentry_id_option 'gnulinux-advanced-#{UUID}' {\n" if @submenu
    ks.each do |k|
      cfg << "menuentry 'Ubuntu, with Linux #{k}' --class ubuntu $menuentry_id_option 'gnulinux-#{k}-advanced-#{UUID}' {\n#{entry_body(k)}}\n"
      cfg << "menuentry 'Ubuntu, with Linux #{k} (recovery mode)' --class ubuntu $menuentry_id_option 'gnulinux-#{k}-recovery-#{UUID}' {\n#{entry_body(k, recovery: true)}}\n"
    end
    cfg << "}\n" if @submenu
    cfg << "### END /etc/grub.d/10_linux ###\n"
    script = File.join(@root, "etc/grub.d/42_ubicloud_pvm")
    cfg << "### BEGIN /etc/grub.d/42_ubicloud_pvm ###\n#{interpret(File.read(script))}### END /etc/grub.d/42_ubicloud_pvm ###\n" if File.executable?(script)
    custom = File.join(@root, "etc/grub.d/40_custom")
    cfg << File.read(custom).lines.reject { |l| l.start_with?("#", "exec") }.join if File.exist?(custom)
    write("boot/grub/grub.cfg", cfg)
    ["Generating grub configuration file ...\ndone\n", 0]
  end

  def entry_body(k, recovery: false)
    args = recovery ? "ro recovery nomodeset" : "ro #{CMDLINE_DEFAULT}"
    initrd = File.exist?(File.join(@root, "boot/initrd.img-#{k}")) ? "\tinitrd\t/boot/initrd.img-#{k}\n" : ""
    if @partuuid && k == @stock
      "\tif [ \"${initrdfail}\" = 1 ]; then\n\t  linux\t/boot/vmlinuz-#{k} root=UUID=#{UUID} #{args}\n#{initrd}\telse\n\t  linux\t/boot/vmlinuz-#{k} root=PARTUUID=#{UUID} #{args} panic=-1\n\tfi\n\tinitrdfail\n"
    else
      "\tsearch --no-floppy --fs-uuid --set=root #{UUID}\n\tlinux\t/boot/vmlinuz-#{k} root=UUID=#{UUID} #{args}\n#{initrd}"
    end
  end

  # Runs the generated 42_ubicloud_pvm the way grub-mkconfig would, for
  # the lines it has: the kernel test, the echoes and the device line.
  def interpret(script)
    kernel = script[%r{^k=(/boot/vmlinuz-\S+)$}, 1]
    return "" unless File.exist?(File.join(@root, kernel))

    script.lines.filter_map do |line|
      if line.start_with?("prepare_grub_to_access_device")
        "  search --no-floppy --fs-uuid --set=root #{UUID}\n"
      elsif (text = line[/\Aecho "(.*)"$/, 1])
        text.gsub('$(make_system_path_relative_to_its_root "$k")', kernel)
          .gsub(%r{\$\(make_system_path_relative_to_its_root (/boot/\S+)\)}) { $1 }
          .gsub("${GRUB_DEVICE_UUID}", @device_uuid)
          .gsub("${GRUB_CMDLINE_LINUX}", "")
          .gsub("${GRUB_CMDLINE_LINUX_DEFAULT}", CMDLINE_DEFAULT) + "\n"
      end
    end.join
  end
end
