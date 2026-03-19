# 📋 Documentação Completa do Projeto PA1 + PL#4

## 1. 🗂️ Ficheiros Criados/Modificados (Para Git)

| Ficheiro | Caminho | Descrição | VM1 | VM2 |
|----------|---------|-----------|-----|-----|
| **firewall.sh** | `/home/teomarques/shared/firewall.sh` | Script principal IPTables (PA1) | ✅ | ✅ |
| **firewall.sh** | `/usr/local/bin/firewall.sh` | Cópia executável do script | ✅ | ✅ |
| **firewall.service** | `/etc/systemd/system/firewall.service` | Serviço systemd para firewall | ✅ | ✅ |
| **suricata.yaml** | `/etc/suricata/suricata.yaml` | Configuração Suricata | ✅ | ⚠️ |
| **local.rules** | `/etc/suricata/rules/local.rules` | Regras personalizadas Suricata | ✅ | ⚠️ |
| **suricata-ips.service** | `/etc/systemd/system/suricata-ips.service` | Serviço systemd Suricata IPS | ⚠️ | ⚠️ |
| **sysctl.conf** | `/etc/sysctl.conf` | IP forwarding persistente | ✅ | ✅ |
| **fstab** | `/etc/fstab` | Mount shared folder | ✅ | ✅ |

---

## 2. 📝 Sequência de Comandos e Atividades Realizadas

### **FASE 1: Configuração Inicial das VMs**

```bash
# 1.1 Configurar Shared Folder no VMware
# (Settings → Options → Shared Folders → Always Enabled → Add "shared")

# 1.2 Instalar VMware Tools (ambas as VMs)
sudo yum install -y open-vm-tools open-vm-tools-desktop
sudo systemctl restart vmtoolsd
sudo systemctl status vmtoolsd

# 1.3 Verificar shared folders disponíveis
vmware-hgfsclient
# Output: shared

# 1.4 Criar diretório de montagem
mkdir -p /home/teomarques/shared

# 1.5 Configurar /etc/fstab para montagem automática
sudo vim /etc/fstab
# Adicionar linha:
# .host:/shared   /home/teomarques/shared   fuse.vmhgfs-fuse   allow_other,uid=1000,gid=1000,umask=022,_netdev   0 0

# 1.6 Montar shared folder
sudo systemctl daemon-reload
sudo mount -a
df -h | grep shared

# 1.7 Testar escrita na shared folder
echo "Teste $(date) - $(hostname)" > /home/teomarques/shared/teste.txt
cat /home/teomarques/shared/teste.txt
```

---

### **FASE 2: Configuração do Firewall IPTables (PA1)**

```bash
# 2.1 Copiar firewall.sh da shared folder para local executável
sudo cp /home/teomarques/shared/firewall.sh /usr/local/bin/firewall.sh
sudo chmod +x /usr/local/bin/firewall.sh

# 2.2 Instalar iptables-services
sudo yum install -y iptables-services

# 2.3 Configurar IP Forwarding persistente
echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
cat /proc/sys/net/ipv4/ip_forward
# Output: 1

# 2.4 Criar serviço systemd para firewall
sudo vim /etc/systemd/system/firewall.service
# Conteúdo:
# [Unit]
# Description=Custom Firewall Configuration (PA1)
# Before=network.target
# After=network.target
# [Service]
# Type=oneshot
# ExecStart=/usr/local/bin/firewall.sh
# RemainAfterExit=yes
# [Install]
# WantedBy=multi-user.target

# 2.5 Ativar e iniciar serviço firewall
sudo systemctl daemon-reload
sudo systemctl enable firewall
sudo systemctl start firewall
sudo systemctl status firewall

# 2.6 Verificar regras IPTables aplicadas
sudo iptables -L -n | head -30
sudo iptables -t nat -L -n
sudo iptables -L FORWARD -n | head -10
```

---

### **FASE 3: Instalação e Configuração do Suricata (PL#4 + PA1)**

```bash
# 3.1 Instalar EPEL (necessário para Suricata)
sudo yum install -y epel-release
sudo yum makecache

# 3.2 Instalar Suricata (VM1 - funcionou)
sudo yum install -y suricata suricata-update
suricata -V
# Output: This is Suricata version 7.0.13 RELEASE

# 3.3 Verificar diretórios criados
ls -la /etc/suricata/
ls -la /var/log/suricata/

# 3.4 Configurar suricata.yaml
sudo cp /etc/suricata/suricata.yaml /etc/suricata/suricata.yaml.backup
sudo vim /etc/suricata/suricata.yaml

# Alterações principais:
# - HOME_NET: [192.168.10.0/24,23.214.219.128/25]
# - af-packet interface: ens33
# - pcap-log enabled: yes
# - outputs: eve-log, fast, stats
# - rule-files: suricata.rules, local.rules

# 3.5 Criar regras personalizadas em local.rules
sudo vim /etc/suricata/rules/local.rules

# Regras PL#4:
# - alert icmp ... (msg:"PL4 ICMP Packet Detected")
# - alert http ... (msg:"PL4 HTTP POST Command Detected")

# Regras PA1:
# - alert tcp ... (msg:"PA1 Port Scan Detected")
# - alert http ... (msg:"PA1 SQL Injection Attempt")
# - alert http ... (msg:"PA1 XSS Attempt Script Tag")

# 3.6 Criar diretório para PCAP logs
sudo mkdir -p /var/log/suricata/pcaps/
sudo chown -R suricata:suricata /var/log/suricata/

# 3.7 Validar configuração Suricata
sudo suricata -T -c /etc/suricata/suricata.yaml
echo $?
# Output: 0 (sucesso)
```

---

### **FASE 4: Integração Suricata + IPTables (NFQUEUE/IPS)**

```bash
# 4.1 Adicionar NFQUEUE ao firewall.sh
sudo vim /usr/local/bin/firewall.sh
# Adicionar antes do echo final:
# iptables -N SURICATA_INSPECT 2>/dev/null || iptables -F SURICATA_INSPECT
# iptables -A SURICATA_INSPECT -p tcp --dport 80 -j NFQUEUE --queue-num 0
# iptables -A SURICATA_INSPECT -p tcp --dport 443 -j NFQUEUE --queue-num 0
# iptables -I FORWARD 1 -j SURICATA_INSPECT

# 4.2 Reaplicar firewall após alterações
sudo systemctl restart firewall

# 4.3 Criar serviço systemd para Suricata IPS
sudo vim /etc/systemd/system/suricata-ips.service
# Conteúdo:
# [Unit]
# Description=Suricata IPS Mode (PA1)
# After=network.target firewall.service
# Wants=firewall.service
# [Service]
# Type=simple
# ExecStart=/usr/bin/suricata -c /etc/suricata/suricata.yaml -q 0
# Restart=on-failure
# [Install]
# WantedBy=multi-user.target

# 4.4 Ativar serviço Suricata
sudo systemctl daemon-reload
sudo systemctl enable suricata-ips
sudo systemctl start suricata-ips
sudo systemctl status suricata-ips
```

---

### **FASE 5: Testes de Validação**

```bash
# 5.1 Testar ICMP (PL#4 Exercício 1)
ping -c 3 10.5.0.1
sudo tail -f /var/log/suricata/fast.log
# Deve mostrar: "PL4 ICMP Packet Detected"

# 5.2 Testar HTTP POST (PL#4 Exercício 2)
curl -X POST http://10.5.0.1/test.php
sudo grep "POST" /var/log/suricata/fast.log

# 5.3 Testar Port Scan (PA1)
sudo nmap -sS -p 1-100 10.5.0.1
sudo grep "Port Scan" /var/log/suricata/fast.log

# 5.4 Testar SQL Injection (PA1)
curl "http://10.5.0.1/index.php?id=1' OR '1'='1"
sudo grep "SQL Injection" /var/log/suricata/fast.log

# 5.5 Testar XSS (PA1)
curl "http://10.5.0.1/page.php?name=<script>alert('XSS')</script>"
sudo grep "XSS" /var/log/suricata/fast.log

# 5.6 Verificar PCAP logs (PL#4 Exercício 3)
ls -la /var/log/suricata/pcaps/
sudo tcpdump -r /var/log/suricata/pcaps/log.pcap -n | head -20

# 5.7 Exportar logs para shared folder (para relatório)
sudo cp /var/log/suricata/fast.log /home/teomarques/shared/suricata_fast.log
sudo cp /var/log/suricata/eve.json /home/teomarques/shared/suricata_eve.json
sudo cp -r /var/log/suricata/pcaps/ /home/teomarques/shared/suricata_pcaps/
```

---

## 3. ✅ Tasklist - O Que Falta Fazer

### **Prioridade Alta (Obrigatório para Entrega)**

| Task | VM1 | VM2 | Status |
|------|-----|-----|--------|
| Instalar Suricata na VM2 | - | ⚠️ | **PENDENTE** |
| Configurar suricata.yaml na VM2 | - | ⚠️ | **PENDENTE** |
| Criar local.rules na VM2 | - | ⚠️ | **PENDENTE** |
| Criar serviço suricata-ips.service | ⚠️ | ⚠️ | **PENDENTE** |
| Testar todos os ataques (ICMP, POST, Port Scan, SQLi, XSS) | ⚠️ | ⚠️ | **PENDENTE** |
| Exportar logs para shared folder | ⚠️ | ️ | **PENDENTE** |
| Validar persistência após reboot | ⚠️ | ⚠️ | **PENDENTE** |

### **Prioridade Média (Relatório)**

| Task | Status |
|------|--------|
| Documentar arquitetura de rede (diagrama) | ⚠️ |
| Explicar cada regra IPTables no relatório | ⚠️ |
| Explicar cada regra Suricata no relatório | ⚠️ |
| Capturar screenshots dos testes | ⚠️ |
| Compilar logs de evidência | ⚠️ |

### **Prioridade Baixa (Entrega Final)**

| Task | Status |
|------|--------|
| Assinar arquivo com PGP | ⚠️ |
| Encriptar com PGP do professor | ⚠️ |
| Submeter via Inforestudante | ⚠️ |

---

## 4. 📁 Estrutura Recomendada para Git Repository

```
PA1_FSI_2025/
├── README.md                    # Este documento de progresso
├── firewall/
│   ├── firewall.sh              # Script IPTables principal
│   ├── firewall.service         # Serviço systemd
│   └── iptables_rules.txt       # Output de 'iptables-save'
├── suricata/
│   ├── suricata.yaml            # Configuração Suricata
│   ├── local.rules              # Regras personalizadas
│   └── suricata-ips.service     # Serviço systemd Suricata
├── logs/
│   ├── fast.log                 # Alertas Suricata
│   ├── eve.json                 # Alertas JSON
│   └── pcaps/                   # Capturas de pacotes
├── report/
│   ├── relatorio.md             # Relatório principal
│   ├── diagrams/                # Diagramas de arquitetura
│   └── screenshots/             # Evidências dos testes
└── delivery/
    └── PA1_grupo_X.asc          # Arquivo assinado/encriptado
```

---

## 5. 🚀 Próximos Passos Imediatos

```bash
# 1. VM2 - Instalar Suricata (precisa desativar firewall temporariamente)
sudo systemctl stop firewall
sudo iptables -P OUTPUT ACCEPT
sudo yum install -y epel-release
sudo yum makecache
sudo yum install -y suricata suricata-update
suricata -V

# 2. VM2 - Copiar configuração da VM1 via shared folder
sudo cp /home/teomarques/shared/suricata.yaml /etc/suricata/suricata.yaml
sudo cp /home/teomarques/shared/local.rules /etc/suricata/rules/local.rules

# 3. Ambas as VMs - Criar serviço suricata-ips
sudo vim /etc/systemd/system/suricata-ips.service
sudo systemctl daemon-reload
sudo systemctl enable suricata-ips
sudo systemctl start suricata-ips

# 4. Ambas as VMs - Testar e exportar logs
sudo systemctl status suricata-ips
sudo cp /var/log/suricata/*.log /home/teomarques/shared/

# 5. Git - Commit e push
cd ~/PA1_FSI_2025
git add .
git commit -m "PA1: Firewall + Suricata configurados"
git push origin main
```

---

## 6. 📊 Resumo do Estado Atual

| Componente | VM1 | VM2 |
|------------|-----|-----|
| **Shared Folder** | ✅ Funcional | ✅ Funcional |
| **firewall.sh** | ✅ Configurado | ✅ Configurado |
| **firewall.service** | ✅ Ativo | ✅ Ativo |
| **IP Forwarding** | ✅ Persistente | ✅ Persistente |
| **Suricata instalado** | ✅ Sim | ❌ Não |
| **suricata.yaml** | ✅ Configurado | ❌ Não |
| **local.rules** | ✅ Criado | ❌ Não |
| **suricata-ips.service** | ❌ Não |  Não |
| **Testes de ataques** | ❌ Não |  Não |
| **Logs exportados** | ❌ Não |  Não |

---

**Deadline:** 22/03/2026
**Grupo:** 2 estudantes
**Entrega:** Inforestudante (PGP signed + encrypted)

---


