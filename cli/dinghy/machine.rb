require 'dinghy/constants'
require 'json'
require 'shellwords'

class Machine
  attr_reader :machine_name
  alias :name :machine_name

  def initialize(machine_name)
    @machine_name = machine_name || 'dinghy'
  end

  def create(options = {})
    provider = options['provider']

    out, err = System.capture_output {
      system("create", "-d", provider, *CreateOptions.generate(provider, options), machine_name)
    }

    if System.command_failed?
      $stderr.puts err
      raise("There was an error creating the VM.")
    end
  end

  def up
    unless running?
      out, err = System.capture_output {
        system("start", machine_name)
      }

      if System.command_failed?
        $stderr.puts err
        raise("There was an error bringing up the VM. Dinghy cannot continue.")
      end
    end
  end

  def host_ip
    if provider == 'parallels'
      vm_ip.sub(%r{\.\d+$}, '.2')
    else
      vm_ip.sub(%r{\.\d+$}, '.1')
    end
  end

  def vm_ip
    inspect_driver['IPAddress']
  end

  def ssh_identity_file_path
    # HACK: The xhyve driver returns this as a blank string on v0.2.2 so we
    #       manually build the path ourselves
    ssh_key_path = inspect_driver["SSHKeyPath"]
    if ssh_key_path != ""
      ssh_key_path
    else
      "#{store_path}/id_rsa"
    end
  end

  def provider
    inspect['DriverName']
  end

  def store_path
    driver = inspect_driver
    if driver.key?('StorePath')
      File.join(driver['StorePath'], 'machines', driver['MachineName'])
    else
      inspect['StorePath']
    end
  end

  def inspect
    JSON.parse(`docker-machine inspect #{machine_name} 2>/dev/null`)
  end

  def inspect_driver
    output = inspect
    output['Driver']['Driver'] || output['Driver']
  end

  def status
    if created?
      `docker-machine status #{machine_name}`.strip.downcase
    else
      "not created"
    end
  end

  def running?
    status == "running"
  end

  def mount(unfs)
    puts "Mounting NFS #{unfs.guest_mount_dir}"
    # Remove the existing vbox/vmware/parallels shared folder. Machine now has flags to
    # skip mounting the share at all, but there's no way to apply the flag to an
    # already-created machine. So we have to continue to do this for older VMs.
    ssh("if [ $(grep -c #{Shellwords.escape('/Users[^/]')} /proc/mounts) -gt 0 ]; then sudo umount /Users || true; fi;")

    ssh("sudo mkdir -p #{unfs.guest_mount_dir}")
    ssh("sudo mount -t nfs #{host_ip}:#{unfs.host_mount_dir} #{unfs.guest_mount_dir} -o nfsvers=3,udp,mountport=#{unfs.port},port=#{unfs.port},nolock,hard,intr")
  end

  def ssh(*command)
    system("ssh", machine_name, *command) || raise("ssh command failed")
  end

  def ssh_exec(*command)
    Kernel.exec("docker-machine", "ssh", machine_name, *command)
  end

  def halt
    system("stop", machine_name)
  end

  def upgrade
    if !running?
      up
    end
    system("upgrade", machine_name)
  end

  def destroy(options = {})
    system(*["rm", (options[:force] ? '--force' : nil), machine_name].compact)
  end

  def created?
    `docker-machine status #{machine_name} 2>&1`
    !System.command_failed?
  end

  def system(*cmd)
    Kernel.system("docker-machine", *cmd)
  end

  def translate_provider(name)
    case name
    when "virtualbox"
      "virtualbox"
    when "vmware", "vmware_fusion", "vmwarefusion", "vmware_desktop"
      "vmwarefusion"
    when "xhyve"
      "xhyve"
    when "parallels", "parallels-desktop"
      "parallels"
    else
      nil
    end
  end
end
