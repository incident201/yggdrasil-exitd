# ygg-exitd

`ygg-exitd` — простой UDP-over-Yggdrasil TUN exit daemon.

Программа создаёт TUN-интерфейс, слушает UDP-сокет на Yggdrasil IPv6-адресе и пересылает IP-пакеты между TUN-интерфейсом и подключившимся клиентом.

## Требования

Нужны:

- Linux
- Go
- `iproute2`
- права root для создания и настройки TUN-интерфейса

## Сборка

```bash
go build -o ygg-exitd .
```

После сборки появится бинарник:

```bash
./ygg-exitd
```

## Установка

Скопировать бинарник в системный путь:

```bash
sudo install -m 755 ygg-exitd /usr/local/bin/ygg-exitd
```

Проверить:

```bash
ygg-exitd --help
```

## Запуск

Пример запуска:

```bash
sudo ygg-exitd \
  --listen "[200:xxxx:xxxx:xxxx:xxxx:xxxx:xxxx:xxxx]:40001" \
  --tun-name yggexit0 \
  --tun-cidr 10.66.0.1/24 \
  --tun-mtu 1500
```

С ограничением по конкретному клиентскому Yggdrasil IPv6:

```bash
sudo ygg-exitd \
  --listen "[200:xxxx:xxxx:xxxx:xxxx:xxxx:xxxx:xxxx]:40001" \
  --client-ip "200:yyyy:yyyy:yyyy:yyyy:yyyy:yyyy:yyyy" \
  --tun-name yggexit0 \
  --tun-cidr 10.66.0.1/24 \
  --tun-mtu 1500
```

## Параметры

```text
--listen      UDP-адрес для прослушивания, например [200:...]:40001
--tun-name    имя TUN-интерфейса, по умолчанию yggexit0
--tun-cidr    адрес TUN-интерфейса, по умолчанию 10.66.0.1/24
--tun-mtu     MTU TUN-интерфейса, по умолчанию 1500
--client-ip   необязательный разрешённый IPv6-адрес клиента
```

## Удаление

```bash
sudo rm /usr/local/bin/ygg-exitd
```
