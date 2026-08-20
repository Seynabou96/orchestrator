# Postmortem — Provisioning K3s + Cilium + Helm

Ce document retrace les problèmes réels rencontrés en mettant en place ce cluster (K3s avec CNI personnalisé Cilium), dans l'ordre où ils sont apparus. Objectif : que la prochaine personne (ou moi-même dans 6 mois) ne reparte pas de zéro si ça recasse.

---

## 1. `provision-master.sh` bloque indéfiniment sur `kubectl get nodes`

**Symptôme** : le provisioning Vagrant ne finit jamais, reste bloqué après l'installation de K3s.

**Cause** : avec `--flannel-backend=none` (nécessaire pour installer Cilium à la place de Flannel), le kubelet ne devient **jamais** pleinement opérationnel tant qu'aucun CNI n'est installé. Une boucle `until kubectl get nodes &>/dev/null` ne sort donc jamais — `kubectl get nodes` ne répond pas correctement sans CNI actif.

**Fix** : ne plus attendre `kubectl get nodes` à ce stade. Vérifier seulement que les fichiers `node-token` et `k3s.yaml` ont bien été écrits sur disque (`[ -s fichier ]`), pas que le cluster est healthy.

---

## 2. Le script `get.k3s.io` bloque indéfiniment côté agent

**Symptôme** : le provisioning de l'agent reste bloqué sur `[INFO] systemd: Starting k3s-agent`, sans jamais avancer.

**Cause** : le script d'installation officiel (`curl ... | sh -`) démarre le service **et attend** qu'il devienne `active` avant de rendre la main. Sans CNI, ce service ne devient jamais `active`.

**Fix** : `INSTALL_K3S_SKIP_START=true` à l'installation (n'installe que le binaire/service, sans démarrer), puis démarrer le service nous-mêmes séparément.

---

## 3. `systemctl start k3s` / `k3s-agent` bloque indéfiniment

**Symptôme** : même après le fix #2, `systemctl start k3s` ne rend jamais la main.

**Cause** : le unit systemd de k3s est `Type=notify`. Pour ce type de service, `systemctl start` attend par défaut un signal `READY=1` envoyé par le process — qui n'arrive jamais sans CNI actif (le kubelet ne devient jamais assez healthy pour l'envoyer).

**Fix** : utiliser `systemctl start --no-block`, qui demande à systemd de lancer le service sans attendre ce signal.

---

## 4. `NRestarts=215` — k3s redémarre en boucle infinie malgré `--no-block`

**Symptôme** : `systemctl status k3s` affiche `activating (auto-restart)`, le process termine avec `code=exited, status=0/SUCCESS` puis redémarre, encore et encore (`NRestarts` grimpe sans fin).

**Cause** : combinaison de `Type=notify` (jamais satisfait sans CNI) et `Restart=always` dans le unit systemd — systemd relance le service à chaque sortie, succès ou échec, sans condition. C'était la cause racine derrière les symptômes #1 à #3.

**Fix appliqué dans ce projet (avant le fix définitif #5)** : override systemd `Type=simple` pour que le service soit considéré démarré dès le fork, sans attendre de signal.

---

## 5. ⭐ Cause racine définitive : `ubuntu/focal64` (Ubuntu 20.04) + cgroup v1

**Découverte** : tous les symptômes #1 à #4 n'étaient que des contournements d'un problème plus profond. La vraie cause : **`ubuntu/focal64` utilise cgroup v1**, et les versions récentes de K3s (v1.36.x) ont des soucis de stabilité du kubelet sur cgroup v1 sans CNI — d'où le restart loop permanent.

**Fix définitif** : passer la box Vagrant à **`ubuntu/jammy64`** (Ubuntu 22.04, cgroup v2). Avec ce changement, **aucun des contournements #1 à #4 n'est nécessaire** — le cluster démarre proprement, nœuds `Ready` en moins de 2 minutes après l'installation de Cilium.

**Leçon** : face à un comportement instable et répétitif, il faut à un moment remettre en question une hypothèse plus fondamentale (ici, la box/OS de base) plutôt que d'empiler des contournements sur le symptôme.

---

## 6. `kubectl get --raw /readyz` échoue de façon intermittente

**Symptôme** : `setup-kubectl.sh` échoue son test de connexion, alors que l'apiserver tourne (logs montrent etcd qui sert, admission controllers chargés).

**Cause** : ce n'est PAS un problème de CNI ici — `/readyz` peut légitimement échouer pendant quelques dizaines de secondes au démarrage de l'apiserver, le temps que tous ses `poststarthook` internes terminent (`generic-apiserver-start-informers`, `priority-and-fairness-*`, etc.). Un seul essai immédiat, sans retry, tombe souvent dans cette fenêtre.

**Fix** : boucle de retry avec timeout généreux (180s) autour de `kubectl get --raw='/readyz'`, aussi bien dans `setup-kubectl.sh` que dans `install-cluster-tools.sh` (avant `helm install cilium`, qui peut échouer pour la même raison).

**Piège évité** : ne PAS tester `/readyz` avec un `curl` anonyme direct — cet endpoint retourne `401 Unauthorized` sans authentification. Utiliser `kubectl get --raw=...`, qui passe par le kubeconfig admin.

---

## 7. `repo sealed-secrets not found`

**Symptôme** : `helm install sealed-secrets ...` échoue, alors que `helm repo add sealed-secrets ...` semblait avoir tourné juste avant (masqué par un `|| true`).

**Cause** : le repo a migré de l'organisation GitHub `bitnami-labs` vers `bitnami` le 15 juin 2026. L'ancienne URL (`https://bitnami-labs.github.io/sealed-secrets`) retourne 404 depuis cette date. Le `|| true` sur le `helm repo add` masquait cette erreur silencieusement.

**Fix** : URL mise à jour vers `https://bitnami.github.io/sealed-secrets`. `|| true` retiré sur cette commande précise pour que toute panne future de repo soit visible immédiatement plutôt que masquée.

---

## 8. Alloy en `CrashLoopBackOff` — config River cassée par mes propres commentaires

**Symptôme** : les pods `monitoring-alloy-*` crashent en boucle dès le démarrage.

**Cause** : la configuration Alloy (`charts/monitoring/values.yaml`) est écrite en **River**, le langage de config Alloy — pas en YAML, même si elle est imbriquée dans un fichier YAML via `content: |-`. En River, les commentaires utilisent `//`, pas `#`. Des commentaires explicatifs écrits avec `#` à l'intérieur du bloc cassaient le parsing (`string literal not terminated`, `illegal character U+0023`).

**Fix** : tous les commentaires à l'intérieur du bloc `content:` réécrits en `//`.

---

## 9. `monitoring-loki-chunks-cache` reste `Pending` (Insufficient memory)

**Symptôme** : un pod memcached lié à Loki ne se schedule jamais, `kubectl describe` montre `Insufficient memory` sur les deux nœuds.

**Cause** : le chart Loki active **par défaut** `chunksCache` et `resultsCache` (deux pods memcached), même en mode `Monolithic` — pas évident à anticiper, ce n'est pas spécifique à notre config.

**Fix** : `chunksCache.enabled: false` et `resultsCache.enabled: false` dans `values.yaml`. Loki retombe sur un cache en mémoire (in-memory) plus léger, suffisant à notre échelle.

---

## 10. Grafana `2/3 Running`, readiness probe timeout

**Symptôme** : le conteneur `grafana` répond lentement, `Readiness probe failed: context deadline exceeded`.

**Cause** : pression mémoire réelle sur la machine hôte (swap actif, RAM disponible très basse pendant le démarrage simultané de tout le stack monitoring).

**Fix** : augmentation de la RAM allouée aux VMs (voir `Vagrantfile`, passé de 4096 Mo à plus). Pas un bug de config — une vraie contrainte de capacité, réglée en donnant plus de ressources.

---

## 11. `make test-smoke` s'arrête après une seule ligne sans erreur

**Symptôme** : la commande affiche juste le premier `[STEP]` puis `Complété`, sans exécuter le reste de la recette.

**Cause** : dans un Makefile, chaque ligne d'une recette s'exécute dans son **propre sous-shell** par défaut. Un `kubectl port-forward ... &` lancé sur une ligne meurt avec son sous-shell dès que cette ligne se termine — les lignes suivantes (qui croient pouvoir utiliser ce port-forward) ne le trouvent jamais vraiment "vivant" de manière fiable.

**Fix** : toute la recette regroupée dans un seul appel `bash -c '...'`, pour que le port-forward en arrière-plan et les `curl` qui suivent partagent le même processus shell.

---

## 12. `make test-smoke` retourne `401 Unauthorized` partout

**Symptôme** : tous les appels (`/health`, `/api/movies`, `/api/billing`) retournent du JSON `{"message":"Unauthorized",...}`, alors que les pods sont `Running` et sains.

**Cause** : un `kubectl port-forward ... svc/monitoring-grafana 3000:80` lancé manuellement dans une session précédente était resté actif en arrière-plan, occupant le port local `3000` — le même port que celui utilisé par `api-gateway`. Le `make test-smoke` suivant se connectait donc à **Grafana**, pas à l'api-gateway (la redirection `/login?redirectTo=...` et le `401` sont le comportement normal de Grafana face à une requête non authentifiée, pas un bug applicatif).

**Fix** : Grafana redirigé vers le port local `3001` dans toute la documentation (README, message `make start`), pour ne plus jamais entrer en collision avec le port `3000` d'api-gateway.

**Leçon** : toujours vérifier qu'aucun port-forward d'une session précédente ne traîne en arrière-plan (`ps aux | grep port-forward`) avant de lancer un test qui dépend d'un port précis.

---

## 13. Provisioning bloqué des heures sur le téléchargement du binaire k3s

**Symptôme** : `vagrant up` reste bloqué indéfiniment (testé jusqu'à 2h sans résultat) sur `curl ... get.k3s.io | sh -`, précisément à l'étape `[INFO] Downloading binary`. `apt-get update` juste avant réussit sans problème. Autres VMs/projets se lancent normalement.

**Diagnostic** : un `INSTALL_K3S_MIRROR=cn` avait été ajouté sur conseil externe — à tort, ce mirroir (`rancher-mirror.rancher.cn`) est documenté par Rancher spécifiquement pour les utilisateurs en Chine continentale, sans rapport avec le problème. Après retrait, le blocage persistait sur l'URL GitHub officielle. Diagnostic en 4 étapes depuis la VM (DNS, connexion TCP, HEAD sur l'URL de release, vrai téléchargement avec `curl -v --max-time 60`) : DNS instantané, TLS instantané, HEAD instantané (200 OK, `content-length` correct) — mais le téléchargement réel plafonnait à ~20 Ko/s de façon **soutenue** sur toute sa durée (pas un blocage net à un octet précis, donc pas un MTU blackhole VirtualBox/NAT classique). Même débit constaté en téléchargeant depuis le navigateur sur l'hôte, hors VM — donc pas un problème d'outil (`curl`) ni de VirtualBox : la route réseau vers ce CDN précis (edges GitHub release observés : Lisbonne/Virginie) est bridée, probablement au niveau FAI/peering depuis ce réseau.

**Cause** : débit soutenu insuffisant (pas une coupure) vers le CDN de releases GitHub (`release-assets.githubusercontent.com`, backend Azure Blob) depuis ce réseau précis — indépendant de `curl`, de VirtualBox, et du mirroir Rancher.

**Fix** : téléchargement du binaire k3s **une fois**, en amont, sur l'hôte (`k3s-bin/k3s` à la racine du projet, à côté du `Vagrantfile` — visible automatiquement dans les VMs via le partage `/vagrant`). `aria2c -x16 -s16` (téléchargement multi-connexions) a réduit le temps de ~65 min à ~27-30 min — le serveur ne limitait que partiellement le nombre de connexions parallèles. Les scripts `provision-master.sh` et `provision-agent.sh` détectent la présence de `/vagrant/k3s-bin/k3s` : si présent, installation via `INSTALL_K3S_SKIP_DOWNLOAD=true` (méthode air-gap officielle k3s, copie locale via `install`, quelques secondes) ; sinon, fallback automatique sur le téléchargement standard `get.k3s.io` — pour ne pas casser l'expérience de quelqu'un qui clone ce repo depuis un réseau sans ce problème. `k3s-bin/` est dans `.gitignore` (binaire de 78 Mo, jamais commité).

**Piège évité** : ne pas confondre "ça bloque" (hang net, symptomatique d'un MTU blackhole) et "ça rame indéfiniment à débit constant" (limite de bande passante réelle) — les deux ont la même apparence en surface (`vagrant up` qui ne finit jamais) mais des causes et fixes complètement différents. Le diagnostic en 4 étapes isolées (DNS / TCP / HEAD / GET réel avec timeout) a permis de trancher sans deviner.

**Leçon** : un mirroir ou une optimisation réseau suggéré ailleurs (autre projet, autre fil, forum) n'est valide que pour le contexte géographique/réseau où il a été vérifié — `INSTALL_K3S_MIRROR=cn` en est l'exemple exact : une vraie solution, mais pour un problème et un réseau différents des miens.

---

## 14. `make create` échoue sur Sealed Secrets — en réalité un pull d'image Cilium trop lent

**Symptôme** : `make create` échoue à l'étape Sealed Secrets (`error: timed out waiting for the condition`, `Makefile:88`). En remontant : les pods Cilium restent `Init:0/6` pendant 8-13 min, les nœuds restent `NotReady`, donc aucun pod applicatif (dont `sealed-secrets-controller`) ne peut devenir `Ready` — effet domino, la vraie cause est plus haut dans la chaîne.

**Diagnostic** : `kubectl describe pod` + `kubectl get events -n kube-system` sur un pod Cilium bloqué montrent que l'init container `config` attend toujours l'image `quay.io/cilium/cilium:v1.20.1` (`Pulling`, jamais de `Pulled` après 12+ min), alors que les images plus petites du même DaemonSet (`cilium-envoy` 73 Mo, `operator-generic` 37 Mo) finissent par se tirer en 42s à 8m44s selon les runs. Débit variable (140 Ko/s à 900 Ko/s) mais insuffisant pour l'image principale (~300-400 Mo) dans la fenêtre de timeout du script (300s + 180s = 8 min).

**Cause** : même famille de cause que #13 (débit réseau limité vers un registre externe, ici `quay.io` plutôt que le CDN GitHub), mais chaque `vagrant destroy` repart de VMs vierges — donc le problème se répète à **chaque** cycle destroy/up, contrairement au binaire k3s qui n'est téléchargé qu'une fois par VM créée.

**Fix** : deux niveaux, complémentaires.
1. **Préchargement** (`Scripts/download-cilium-images.sh`, à lancer sur l'hôte) : `docker pull` + `docker save` des 3 images Cilium en tarballs dans `cilium-images/` (gitignored). `provision-master.sh` et `provision-agent.sh` détectent ces tarballs et font `k3s ctr images import` directement dans containerd, sur chaque nœud, avant que Helm n'installe Cilium — donc plus aucun pull réseau à ce moment. Survit à tous les futurs `vagrant destroy`.
2. **Timeouts augmentés en filet de sécurité** (`install-cluster-tools.sh`) : attente Cilium daemonset 300s → 1200s, attente nœuds Ready 180s → 300s, rollout Sealed Secrets 120s → 300s — pour le cas où quelqu'un clone le repo sans avoir préchargé les images (comportement par défaut inchangé, juste plus patient).

**Piège évité** : l'erreur affichée par `make` pointe sur Sealed Secrets, mais Sealed Secrets n'est pas le problème — il est juste la première étape séquentielle qui dépend d'un nœud `Ready`, donc la première à échouer visiblement. Toujours remonter la chaîne de dépendances (`kubectl get events`, ordre chronologique) plutôt que de corriger l'étape qui affiche l'erreur.

---

## Récapitulatif rapide (pour aller vite la prochaine fois)

| Symptôme | Vraie cause | Fix |
|---|---|---|
| Provisioning bloqué indéfiniment | `flannel-backend=none` + box `focal64`/cgroup v1 | Passer à `jammy64` |
| `NRestarts` qui explose | `Type=notify` + `Restart=always` sans CNI | Résolu de facto par le passage à `jammy64` |
| `readyz` échoue par intermittence | Fenêtre de démarrage normale de l'apiserver | Boucle de retry, pas un seul essai |
| `repo not found` | Migration GitHub bitnami-labs → bitnami | Nouvelle URL |
| Pod crash en boucle (Alloy) | `#` au lieu de `//` dans une config River | Corriger les commentaires |
| Pod `Pending` (Insufficient memory) | Composant activé par défaut non désiré | Désactiver explicitement dans `values.yaml` |
| `make` recette tronquée | Process en arrière-plan dans son propre sous-shell | Tout dans un seul `bash -c '...'` |
| `make test-smoke` → `401` partout | Port-forward Grafana oublié sur le même port que l'app | Grafana sur un port local différent (3001) |
| `vagrant up` bloqué des heures au téléchargement k3s | Débit soutenu insuffisant vers le CDN release GitHub depuis ce réseau (pas un MTU blackhole, pas VirtualBox) | Binaire pré-téléchargé en local (`k3s-bin/`), scripts avec fallback auto vers le téléchargement standard |
| `make create` échoue sur Sealed Secrets (timeout rollout) | Effet domino : image `cilium:v1.20.1` (~300-400 Mo) trop lente à pull depuis quay.io → nœuds jamais Ready → rien ne peut devenir Ready après | Images Cilium préchargées (`cilium-images/`) + import direct via `ctr` dans chaque VM, timeouts augmentés en filet de sécurité |