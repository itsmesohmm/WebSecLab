# Som Web Hacking Lab

A lightweight vulnerable web application lab using Docker.

This project automatically deploys two intentionally vulnerable applications for web security practice:

* **DVWA (Damn Vulnerable Web Application)**
* **OWASP Juice Shop**

The lab runs locally using Docker so you can practice attacks safely without affecting other systems.

---

## Lab Architecture

Kali / Linux Host
│
└── Docker Network
    ├── DVWA
    └── OWASP Juice Shop

---

## Prerequisites

The installer will automatically install:

* Docker
* Docker Compose

Supported systems:

* Kali Linux

---

## Installation

Clone the repository:

```bash
git clone https://github.com/itsmesohmm/som-web-lab.git
cd som-web-lab
```

Run the installer:

```bash
sudo bash install.sh
```

The script will:

1. Install Docker
2. Start Docker service
3. Pull vulnerable images
4. Launch the lab containers

---

## Access the Applications

After installation completes, open your browser.

DVWA:

```
http://10.10.10.10:80
```

OWASP Juice Shop:

```
http://10.10.10.11:3000
```

---

## Verify Containers

You can confirm the lab is running with:

```bash
docker ps
```

You should see containers for:

* dvwa
* juiceshop

---

## Stopping the Lab

To stop all containers:

```bash
docker compose down
```

---

## Restarting the Lab

From the project directory:

```bash
docker compose up -d
```

---



---

## License

MIT License
