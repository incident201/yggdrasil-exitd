# yggdrasil-exitd



`yggdrasil-exitd` — простой серверный termination point для Yggdrasil.



Он позволяет принять трафик от клиента через Yggdrasil и выпустить его дальше во внешний интернет или в другой сетевой интерфейс сервера, например `wg0`, `awg0` или `tun0`.



Проект состоит из двух частей:



- `ygg-exitd` — сам демон, который создаёт TUN-интерфейс и пересылает IP-пакеты через UDP поверх Yggdrasil;

- `install.sh` / `uninstall.sh` — установщик и откатчик системной конфигурации: systemd, nftables, policy routing, sysctl и служебные файлы.



## Что делает ygg-exitd



Демон:



- слушает UDP на Yggdrasil IPv6-адресе сервера;

- создаёт TUN-интерфейс `yggexit0`;

- назначает ему адрес `10.66.0.1/24`;

- принимает IP-пакеты от разрешённых Yggdrasil-клиентов;

- пересылает ответы обратно тому клиенту, от которого пришёл трафик.



По умолчанию используется:



```text

UDP port:   40001

TUN name:   yggexit0

TUN CIDR:   10.66.0.1/24

TUN net:    10.66.0.0/24

TUN MTU:    1280

Whitelist:  /etc/ygg-exitd.conf

```



## Требования



Нужен Linux-сервер с уже установленным и запущенным Yggdrasil.



Установщик сам не устанавливает Yggdrasil, потому что в разных дистрибутивах он ставится по-разному.



На сервере должны быть доступны:



- `systemd`

- `iproute2`

- `nftables`

- `sysctl`

- `go`

- `git`, `curl` или `wget`



На Ubuntu минимально:



```bash

sudo apt update

sudo apt install -y golang-go git nftables iproute2

```



Если версия Go из репозитория дистрибутива слишком старая, поставь свежий Go с официального сайта Go.



## Установка



Склонировать репозиторий:



```bash

git clone https://github.com/incident201/yggdrasil-exitd.git

cd yggdrasil-exitd

```



Запустить установщик:



```bash

chmod +x install.sh uninstall.sh

sudo ./install.sh

```



Установщик:



- проверит, что Yggdrasil поднят;

- автоматически найдёт локальный Yggdrasil IPv6-адрес из диапазона `0200::/7`;

- соберёт `ygg-exitd`;

- установит бинарник в `/usr/local/bin/ygg-exitd`;

- создаст systemd service `ygg-exitd.service`;

- создаст конфиг `/etc/ygg-exitd/ygg-exitd.env`;

- создаст whitelist `/etc/ygg-exitd.conf`;

- создаст отдельную nftables table `inet ygg_exitd`;

- при необходимости включит IPv4 forwarding;

- запустит сервис и добавит его в автозагрузку.



Во время установки нужно выбрать только интерфейс, куда выпускать трафик клиентов.



Например:



```text

ens3    обычный выход в интернет через внешний интерфейс сервера

eth0    обычный выход в интернет через внешний интерфейс сервера

wg0     выпускать трафик клиентов через WireGuard

awg0    выпускать трафик клиентов через AmneziaWG

tun0    выпускать трафик клиентов через другой TUN/VPN-интерфейс

none    не настраивать NAT/forwarding, только поднять сам ygg-exitd

```



## Whitelist клиентов



После установки whitelist пустой.



Это сделано специально: пока ты явно не добавишь Yggdrasil IPv6 клиента, сервер не будет принимать клиентский трафик.



Файл whitelist:



```bash

/etc/ygg-exitd.conf

```



Формат простой: один Yggdrasil IPv6 клиента на строку.



Пример:



```text

# ygg-exitd whitelist

# One allowed client IPv6 address per line.



200:1111:2222:3333:4444:5555:6666:7777

201:aaaa:bbbb:cccc:dddd:eeee:ffff:0001

```



После изменения whitelist перезапусти сервис:



```bash

sudo systemctl restart ygg-exitd

```



## Проверка статуса



Статус сервиса:



```bash

systemctl status ygg-exitd

```



Логи:



```bash

journalctl -u ygg-exitd -f

```



Проверить, что TUN-интерфейс создан:



```bash

ip addr show yggexit0

```



Проверить nftables table:



```bash

sudo nft list table inet ygg_exitd

```



Проверить policy routing:



```bash

ip rule show

ip route show table 42066

```



## Что меняется в системе



Установщик создаёт:



```text

/usr/local/bin/ygg-exitd

/usr/local/sbin/ygg-exitd-run

/usr/local/sbin/ygg-exitd-nft-apply

/usr/local/sbin/ygg-exitd-nft-remove

/usr/local/sbin/ygg-exitd-routing-apply

/usr/local/sbin/ygg-exitd-routing-remove



/etc/ygg-exitd/ygg-exitd.env

/etc/ygg-exitd/nftables.nft

/etc/ygg-exitd/install.state

/etc/ygg-exitd.conf



/etc/systemd/system/ygg-exitd.service

/etc/sysctl.d/99-ygg-exitd.conf

```



Также создаётся отдельная nftables table:



```text

table inet ygg_exitd

```



Установщик не делает `flush ruleset`, не меняет чужие nftables-таблицы и не меняет default policy существующего firewall.



Если на сервере уже есть строгий firewall с `drop` в других таблицах, может потребоваться отдельно разрешить forwarding в существующих правилах firewall.



## Режимы работы



### Выход в обычный интернет



Во время установки укажи внешний интерфейс сервера, например:



```text

ens3

eth0

enp1s0

```



В этом режиме трафик из `10.66.0.0/24` будет NAT-иться наружу через выбранный интерфейс.



### Выход через другой VPN



Если нужно выпускать трафик клиентов через другой VPN, укажи VPN-интерфейс:



```text

wg0

awg0

tun0

```



В этом режиме установщик добавляет policy routing только для подсети `10.66.0.0/24`. Обычная маршрутизация самого сервера не должна меняться.



### Без NAT/forwarding



Если выбрать:



```text

none

```



установщик поднимет только сам `ygg-exitd`, без NAT и без forwarding-правил.



## Удаление



Из каталога репозитория:



```bash

sudo ./uninstall.sh

```



Скрипт удаления:



- остановит и отключит `ygg-exitd.service`;

- удалит systemd unit;

- удалит бинарник и helper scripts;

- удалит `/etc/ygg-exitd`;

- удалит nftables table `inet ygg_exitd`;

- удалит policy routing table/rule, созданные установщиком;

- предложит удалить `/etc/ygg-exitd.conf`;

- не будет удалять Yggdrasil и не будет менять его конфиг.



Если до установки `net.ipv4.ip_forward` был выключен, uninstall-скрипт спросит, нужно ли вернуть его обратно в `0`.



## Ручная сборка



Если нужен только бинарник без установки systemd/nftables:



```bash

go build -o ygg-exitd .

```



Запуск вручную:



```bash

sudo ./ygg-exitd \

  --listen "[200:xxxx:xxxx:xxxx:xxxx:xxxx:xxxx:xxxx]:40001" \

  --tun-name yggexit0 \

  --tun-cidr 10.66.0.1/24 \

  --tun-mtu 1280

```



При ручном запуске NAT, forwarding, policy routing и systemd нужно настраивать самостоятельно.



## Важное замечание по безопасности



Не добавляй в whitelist чужие Yggdrasil IPv6-адреса.



Любой клиент из whitelist сможет использовать этот сервер как exit point в зависимости от выбранного режима маршрутизации.



