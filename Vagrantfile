Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/focal64"
  config.vm.box_check_update = false
  
  # # Configuration réseau globale - CORRECTIONS COMPLÈTES
  # config.vm.provider "virtualbox" do |vb|
  #   vb.linked_clone = true
  #   # Désactiver le DNS natif de VirtualBox
  #   vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
  #   vb.customize ["modifyvm", :id, "--natdnsproxy1", "on"]
    
  #   # CONFIGURATION RÉSEAU CRITIQUE POUR K3s
  #   # vb.customize ["modifyvm", :id, "--nictype1", "virtio"]        # Interface NAT (virtio pour meilleures perf)
  #   # vb.customize ["modifyvm", :id, "--nictype2", "virtio"]        # Interface host-only (virtio)
  #   # vb.customize ["modifyvm", :id, "--nicpromisc2", "allow-all"]  # PERMETTRE TOUT LE TRAFIC (essentiel)
  #   # vb.customize ["modifyvm", :id, "--cableconnected2", "on"]     # S'assurer que le câble est connecté
  # end

  # Master Node
  config.vm.define "master", primary: true do |master|
    master.vm.hostname = "master"
    master.vm.network "private_network", ip: "192.168.56.10"
    
    master.vm.provider "virtualbox" do |vb|
      vb.name = "k3s-master"
      vb.memory = "2048"
      vb.cpus = 2
      vb.customize ["modifyvm", :id, "--groups", "/K3s-Cluster"]
      
      # Configuration réseau spécifique au master
      vb.customize ["modifyvm", :id, "--macaddress2", "080027AAAAAA"]  # MAC fixe optionnelle
    end
    
    # Copier le script de provisionnement dans la VM
    master.vm.provision "file", source: "./Scripts/provision-master.sh", destination: "/tmp/provision-master.sh"
    
    # Exécuter le script de provisionnement
    master.vm.provision "shell", inline: <<-SHELL
      chmod +x /tmp/provision-master.sh
      /tmp/provision-master.sh
    SHELL
    
    # Message de fin pour le master
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
      vb.memory = "2048"
      vb.cpus = 2
      vb.customize ["modifyvm", :id, "--groups", "/K3s-Cluster"]
      
      # Configuration réseau spécifique à l'agent
      vb.customize ["modifyvm", :id, "--macaddress2", "080027BBBBBB"]  # MAC fixe optionnelle
    end
    
    # Copier le script de provisionnement dans la VM
    agent.vm.provision "file", source: "./Scripts/provision-agent.sh", destination: "/tmp/provision-agent.sh"

    # Exécuter le script de provisionnement
    agent.vm.provision "shell", inline: <<-SHELL
      chmod +x /tmp/provision-agent.sh
      /tmp/provision-agent.sh
    SHELL
    
    # Message de fin et vérification du cluster
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
      echo "   Testez (exemple): kubectl apply -f test-deployment.yaml"
      echo ""
    SHELL
  end
end