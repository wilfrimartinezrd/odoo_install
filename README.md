# Odoo Script de Instalación

Script para instalar **Odoo base (Community + Enterprise)** sobre Ubuntu,
de la **12.0 a la 19.0** según la variable `OE_VERSION`.

El servidor queda con Odoo "limpio": las localizaciones y los addons
custom **no** se instalan aquí — se cargan después como paso separado.

---

## Procedimiento de instalación

##### 1. Descarga el script

```
sudo wget https://raw.githubusercontent.com/wilfrimartinezrd/odoo_install/refs/heads/main/odoo_install.sh
```

##### 2. Haz el script ejecutable

```
sudo chmod +x odoo_install.sh
```

##### 3. Ejecuta el script con la versión que quieras

```bash
sudo ./odoo_install.sh                   # Odoo 19 (por defecto)
sudo OE_VERSION=18.0 ./odoo_install.sh   # Odoo 18
sudo OE_VERSION=17.0 ./odoo_install.sh   # Odoo 17
sudo OE_VERSION=16.0 ./odoo_install.sh   # Odoo 16
sudo OE_VERSION=15.0 ./odoo_install.sh   # Odoo 15
sudo OE_VERSION=14.0 ./odoo_install.sh   # Odoo 14
sudo OE_VERSION=13.0 ./odoo_install.sh   # Odoo 13
sudo OE_VERSION=12.0 ./odoo_install.sh   # Odoo 12
```

Al terminar, Odoo queda escuchando en `http://<IP>:8069`.

> **Enterprise**: por defecto `IS_ENTERPRISE=True`, lo que requiere que la
> clave SSH de root tenga acceso a `git@github.com:odoo/enterprise.git`
> (acceso de partner). Para instalar solo Community:
> `sudo IS_ENTERPRISE=False ./odoo_install.sh`

---

## Requisitos mínimos del servidor

Aunque técnicamente se puede correr Odoo con 1GB de RAM, no es
recomendable. Una instancia de Linux normalmente usa entre 300MB y
500MB, y el resto se reparte entre Odoo, PostgreSQL y otros servicios.
Para una instalación estable se recomiendan **al menos 2GB de RAM**.

---

## Compatibilidad de versiones de Odoo y Ubuntu

| Versión de Odoo | Versión de Ubuntu recomendada |
| --------------- | ----------------------------- |
| Odoo 12         | Ubuntu 18.04                  |
| Odoo 13         | Ubuntu 20.04                  |
| Odoo 14         | Ubuntu 20.04                  |
| Odoo 15         | Ubuntu 20.04                  |
| Odoo 16         | Ubuntu 22.04                  |
| Odoo 17         | Ubuntu 22.04                  |
| Odoo 18         | Ubuntu 24.04                  |
| Odoo 19         | Ubuntu 24.04                  |

Es importante usar la versión correcta de Ubuntu: cada versión de Odoo
solo funciona con ciertas versiones de Python, y el script **verifica la
compatibilidad y aborta** si el Python del sistema no corresponde a la
`OE_VERSION` pedida (se puede forzar con `SKIP_PY_CHECK=True`).
