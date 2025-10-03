# # -*- mode: ruby -*-
# # vi: set ft=ruby :

# Vagrant.configure("2") do |config|
#   # Configuration de base
#   config.vm.box = "ubuntu/jammy64"
#   config.vm.box_version = "20240319.0.0"
  
#   # Disable default shared folder for WSL compatibility
#   config.vm.synced_folder ".", "/vagrant", disabled: true
  
#   # Configuration du nœud Master K3s uniquement
#   config.vm.define "master" do |master|
#     master.vm.hostname = "k3s-master"
    
#     # Port forwarding for K3s API and local HTTP server
#     master.vm.network "forwarded_port", guest: 6443, host: 6443
#     master.vm.network "forwarded_port", guest: 8080, host: 8080
    
#     master.vm.provider "virtualbox" do |vb|
#       vb.name = "k3s-master"
#       vb.memory = "2048"
#       vb.cpus = 2
#     end
    
#     # Provisioning du master
#     master.vm.provision "shell", inline: <<-SHELL
#       # Mise à jour du système
#       apt-get update -y
#       apt-get upgrade -y
      
#       # Installation des dépendances
#       apt-get install -y curl wget software-properties-common
      
#       # Configuration du hostname
#       hostnamectl set-hostname k3s-master
      
#       # Installation de K3s Master
#       curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --bind-address=0.0.0.0" sh -
      
#       # Attendre que K3s soit prêt
#       sleep 30
      
#       # Create shared directory and save token
#       mkdir -p /tmp/k3s-shared
#       cat /var/lib/rancher/k3s/server/node-token > /tmp/k3s-shared/node-token
      
#       # Copier le kubeconfig pour l'accès externe
#       cp /etc/rancher/k3s/k3s.yaml /tmp/k3s-shared/kubeconfig
#       sed -i 's/127.0.0.1/localhost/g' /tmp/k3s-shared/kubeconfig
#       chmod 644 /tmp/k3s-shared/kubeconfig
      
#       # Configurer kubectl pour l'utilisateur vagrant
#       mkdir -p /home/vagrant/.kube
#       cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
#       chown vagrant:vagrant /home/vagrant/.kube/config
      
#       # Setup simple HTTP server to share files
#       cd /tmp/k3s-shared
#       nohup python3 -m http.server 8080 > /dev/null 2>&1 &
      
#       echo "✅ Master K3s installé avec succès!"
#       echo "📋 Token disponible via HTTP sur localhost:8080/node-token"
#       echo "🔧 Kubeconfig disponible via HTTP sur localhost:8080/kubeconfig"
#       echo "🎯 Kubectl access: kubectl --kubeconfig=/tmp/k3s-shared/kubeconfig get nodes"
#     SHELL
#   end
# end





Vagrant.configure("2") do |config|
  config.vm.box = "bento/ubuntu-22.04"
  
  # Configuration du Master Node
  config.vm.define "master" do |master|
    master.vm.hostname = "masterS"
    master.vm.network "private_network", ip: "192.168.56.110"
    
    master.vm.provider "virtualbox" do |vb|
      vb.name = "master"
      vb.memory = "2048"
      vb.cpus = 2
    end
    
    master.vm.provision "shell", inline: <<-SHELL
      # Installation de K3s en mode server (master)
      curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --node-name=masterS --flannel-iface=eth1" sh -
      
      # Attendre que K3s soit prêt
      sleep 10
      
      # Récupérer le token pour les agents
      sudo cat /var/lib/rancher/k3s/server/node-token > /vagrant/node-token
      
      # Copier le kubeconfig pour kubectl
      sudo cat /etc/rancher/k3s/k3s.yaml > /vagrant/kubeconfig.yaml
      sudo sed -i 's/127.0.0.1/192.168.56.110/g' /vagrant/kubeconfig.yaml
      
      echo "Master node configuré avec succès"
    SHELL
  end
  
  # Configuration de l'Agent Node
  config.vm.define "agent" do |agent|
    agent.vm.hostname = "agentS"
    agent.vm.network "private_network", ip: "192.168.56.111"
    
    agent.vm.provider "virtualbox" do |vb|
      vb.name = "agent"
      vb.memory = "1024"
      vb.cpus = 1
    end
    
    agent.vm.provision "shell", inline: <<-SHELL
      # Attendre que le fichier token soit disponible
      while [ ! -f /vagrant/node-token ]; do
        echo "Attente du token du master..."
        sleep 2
      done
      
      TOKEN=$(cat /vagrant/node-token)
      
      # Installation de K3s en mode agent
      curl -sfL https://get.k3s.io | K3S_URL=https://192.168.56.110:6443 K3S_TOKEN=$TOKEN INSTALL_K3S_EXEC="agent --node-name=agentS --flannel-iface=eth1" sh -
      
      echo "Agent node configuré avec succès"
    SHELL
  end
end