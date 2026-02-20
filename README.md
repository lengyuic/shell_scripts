# 1.dd 重装
```
curl -O https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh || wget -O ${_##*/} $_

bash ./reinstall.sh debian 13 --ssh-key "密钥 自行替换" --ssh-port 51022
```

# 2. 安装常用软件
```
apt install vim git curl tar wget zsh -y

sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

sed 's/ZSH_THEME="robbyrussell"/ZSH_THEME="ys"/' ~/.zshrc
source ~/.zshrc

usermod -s /bin/zsh root
```

# 3. vim 修改鼠标
```
echo "set mouse=" > ~/.vimrc
```

# 4. 禁用ssh密钥登录
```
curl -fsSL https://raw.githubusercontent.com/lengyuic/shell_scripts/refs/heads/main/fail2ban_setup.sh | sh
```

# 6. singbox 脚本配置(二选一 执行)
## ① 优化机器(中转机) 配置
### I. vless+reality
```
TAG="Test" sh -c "$(curl -fsSL https://raw.githubusercontent.com/lengyuic/shell_scripts/refs/heads/main/singbox_setup_proxy.sh)"
```

### II. anyreality
```
TAG="Test" sh -c "$(curl -fsSL https://raw.githubusercontent.com/lengyuic/shell_scripts/refs/heads/main/singbox_setup_anyreality.sh)"
```

## ② 落地机 配置
### I. 配置singbox
```
TAG="Test" sh -c "$(curl -fsSL https://raw.githubusercontent.com/lengyuic/shell_scripts/refs/heads/main/singbox_setup_landing.sh)"
```

### II. 开启白名单
```
admin|user
RELAY_IP="ip1|ip2,ip3" sh -c "$(curl -fsSL https://raw.githubusercontent.com/lengyuic/shell_scripts/refs/heads/main/firewall_setup.sh)"
```
