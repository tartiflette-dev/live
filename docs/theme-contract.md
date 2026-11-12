# Contrat de thème : custom properties CSS consommées par l'app

Généré par `script/theme-contract` (ne pas éditer à la main ; `script/theme-contract --check`
échoue si ce document n'est pas à jour, `test/lib/theme_contract_test.rb` le vérifie).

Contrat complet d'un pack : [theme-pack.md](theme-pack.md). Un pack `themes/<nom>/tokens.css` doit définir **toutes les propriétés obligatoires**, en mode
clair (`:root`) et, s'il le souhaite, en mode sombre (`[data-theme="dark"]`). Les propriétés
facultatives sont toujours lues avec une valeur de repli.

Obligatoires : **54** · facultatives : **0**.

## Obligatoires

### `--accent-*` (2)

- `--accent` — 4 fichiers
- `--accent-hover` — 1 fichier

### `--border-*` (5)

- `--border` — 4 fichiers
- `--border-color-strong` — 2 fichiers
- `--border-control` — 4 fichiers
- `--border-width-hairline` — 4 fichiers
- `--border-width-strong` — 3 fichiers

### `--focus-*` (1)

- `--focus-ring` — 2 fichiers

### `--font-*` (2)

- `--font-mono` — 4 fichiers
- `--font-sans` — 4 fichiers

### `--gray-*` (9)

- `--gray-350` — 3 fichiers
- `--gray-50` — 2 fichiers
- `--gray-500` — 1 fichier
- `--gray-600` — 1 fichier
- `--gray-700` — 2 fichiers
- `--gray-800` — 2 fichiers
- `--gray-850` — 2 fichiers
- `--gray-900` — 2 fichiers
- `--gray-925` — 3 fichiers

### `--on-*` (1)

- `--on-accent` — 3 fichiers

### `--orange-*` (2)

- `--orange-400` — 2 fichiers
- `--orange-500` — 2 fichiers

### `--radius-*` (4)

- `--radius-card` — 6 fichiers
- `--radius-interactive` — 6 fichiers
- `--radius-none` — 1 fichier
- `--radius-window` — 1 fichier

### `--space-*` (7)

- `--space-1` — 4 fichiers
- `--space-16` — 1 fichier
- `--space-2` — 4 fichiers
- `--space-3` — 4 fichiers
- `--space-4` — 4 fichiers
- `--space-6` — 2 fichiers
- `--space-8` — 2 fichiers

### `--status-*` (7)

- `--status-critical` — 4 fichiers
- `--status-critical-dark` — 4 fichiers
- `--status-info` — 1 fichier
- `--status-pending-dark` — 1 fichier
- `--status-success` — 1 fichier
- `--status-success-dark` — 1 fichier
- `--status-warning` — 2 fichiers

### `--surface-*` (2)

- `--surface` — 4 fichiers
- `--surface-raised` — 4 fichiers

### `--text-*` (3)

- `--text-accent` — 3 fichiers
- `--text-primary` — 4 fichiers
- `--text-secondary` — 4 fichiers

### `--type-*` (9)

- `--type-h2-leading` — 1 fichier
- `--type-h2-size` — 1 fichier
- `--type-h2-tracking` — 1 fichier
- `--type-h2-weight` — 1 fichier
- `--type-h3-leading` — 1 fichier
- `--type-h3-size` — 2 fichiers
- `--type-h3-tracking` — 1 fichier
- `--type-h3-weight` — 1 fichier
- `--type-small-size` — 4 fichiers

## Facultatives (lues avec repli)
