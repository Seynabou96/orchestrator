Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"  # 22.04 LTS — cgroup v2 natif, requis par K3s >= v1.30 et Cilium >= 1.16 (ubuntu/jammy64)
  config.vm.box_check_update = false

  # Master Node
  config.vm.define "master", primary: true do |master|
    master.vm.hostname = "master"
    master.vm.network "private_network", ip: "192.168.56.10"

    master.vm.provider "virtualbox" do |vb|
      vb.name = "k3s-master"
      # 5120 Mo (5 Go) — augmenté depuis 4096 Mo : pression mémoire
      # réelle constatée (swap actif) une fois tout le stack monitoring
      # (Prometheus + Grafana + Loki + Alloy) démarré en plus des 6
      # services applicatifs et de Cilium. Voir
      # docs/troubleshooting/POSTMORTEM.md, point #10.
      vb.memory = "5120"
      vb.cpus = 2
      vb.customize ["modifyvm", :id, "--groups", "/K3s-Cluster"]
      vb.customize ["modifyvm", :id, "--macaddress2", "080027AAAAAA"]
    end

    master.vm.provision "file", source: "./Scripts/provision-master.sh", destination: "/tmp/provision-master.sh"
    master.vm.provision "shell", inline: <<-SHELL
      chmod +x /tmp/provision-master.sh
      /tmp/provision-master.sh
    SHELL

    master.vm.provision "shell", run: "always", inline: <<-SHELL
      echo ""
      echo "🚀 Master K3s prêt !"
      echo "   IP: 192.168.56.10"
      echo "   Dashboard: kubectl proxy --address 0.0.0.0 --accept-hosts '.*'"
      echo ""
    SHELL
  end

  # Agent Node
  config.vm.define "agent" do |agent|
    agent.vm.hostname = "agent"
    agent.vm.network "private_network", ip: "192.168.56.11"

    agent.vm.provider "virtualbox" do |vb|
      vb.name = "k3s-agent"
      vb.memory = "5120"
      vb.cpus = 2
      vb.customize ["modifyvm", :id, "--groups", "/K3s-Cluster"]
      vb.customize ["modifyvm", :id, "--macaddress2", "080027BBBBBB"]
    end

    agent.vm.provision "file", source: "./Scripts/provision-agent.sh", destination: "/tmp/provision-agent.sh"
    agent.vm.provision "shell", inline: <<-SHELL
      chmod +x /tmp/provision-agent.sh
      /tmp/provision-agent.sh
    SHELL

    agent.vm.provision "shell", run: "always", inline: <<-SHELL
      echo ""
      echo "🎉 Agent K3s joint au cluster !"
      echo "   IP: 192.168.56.11"
      echo ""
      echo "Pour vérifier le cluster depuis le master:"
      echo "   vagrant ssh master"
      echo "   kubectl get nodes -o wide"
      echo ""
      echo "🎯 Pour configurer kubectl sur l'hôte, lancez:"
      echo "   bash ./Scripts/setup-kubectl.sh"
      echo ""
      echo "🌐 Cluster K3s déployé avec succès !"
      echo "   Master: https://192.168.56.10:6443"
      echo ""
    SHELL
  end
end