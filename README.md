# Flamebase Installer

Fast, robust standalone installer for Flamebase Firebase-compatible services on Linux.

## Usage

### Interactive One-Liner
```bash
curl -fsSL https://raw.githubusercontent.com/flamebase/installer/main/install.sh | sh
```

### Unattended Binary Installation
```bash
curl -fsSL https://raw.githubusercontent.com/flamebase/installer/main/install.sh | sh -s -- \
  --mode binary \
  --services auth,firestore,storage \
  --yes
```

### Pinned Version with Docker
```bash
curl -fsSL https://raw.githubusercontent.com/flamebase/installer/main/install.sh | sh -s -- \
  --version v0.1.0 \
  --mode docker \
  --services auth,firestore,storage,functions \
  --yes
```
