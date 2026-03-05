#!/usr/bin/env zsh

# ============================================================
#  AI-CLI  ·  Interface terminal professionnelle
# ============================================================

AI_CLI_ROOT="${AI_CLI_ROOT:-$HOME/ai-cli}"
AGENTS_DIR="$AI_CLI_ROOT/agents"
LOGS_DIR="$AI_CLI_ROOT/logs"
STATE_FILE="$AI_CLI_ROOT/.last_session"
PROFILES_FILE="$AI_CLI_ROOT/.model_profiles"
CONFIG_FILE="$AI_CLI_ROOT/.config"
OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
CONNECTIONS_FILE="$AI_CLI_ROOT/.connections"

# Mode de connexion : ollama (local) | external (serveur OpenAI-compatible)
CONNECTION_MODE="ollama"
ACTIVE_CONNECTION=""   # Nom du profil de connexion actif
EXTERNAL_URL=""        # URL résolue depuis le profil actif (runtime uniquement)
EXTERNAL_API_KEY=""    # Clé déchiffrée (runtime uniquement, jamais persitée)
_MASTER_PASS=""        # Mot de passe maître (session uniquement, jamais écrit)

SELECTED_MODEL=""
SELECTED_AGENT=""
SESSION_ID=""
LOG_FILE=""
PROJECT_DIR=""   # Dossier projet courant (défini au lancement)

# Valeurs par défaut — surchargées par load_config si ~/.config existe
CODE_EXTENSIONS=(php js ts jsx tsx vue py rb go rs java kt swift cs cpp c h css scss sass less html htm xml json yaml yml toml env md sh zsh bash)
EXCLUDED_DIRS=(vendor node_modules .git dist build cache .cache .idea .vscode __pycache__ coverage)

# ── Couleurs ──────────────────────────────────────────────
C_RESET=$'\e[0m'
C_BOLD=$'\e[1m'
C_DIM=$'\e[2m'
C_GREEN=$'\e[38;5;82m'
C_CYAN=$'\e[38;5;51m'
C_YELLOW=$'\e[38;5;220m'
C_RED=$'\e[38;5;196m'
C_MAGENTA=$'\e[38;5;171m'
C_WHITE=$'\e[38;5;255m'
C_GRAY=$'\e[38;5;240m'
C_ORANGE=$'\e[38;5;214m'
C_BLUE=$'\e[38;5;75m'

# ── Utilitaires d'affichage ───────────────────────────────

term_width() { tput cols 2>/dev/null || echo 80 }

_line() {
  local char="${1:-─}" color="${2:-$C_GRAY}"
  local w; w=$(term_width)
  printf "${color}"
  printf '%*s' "$w" '' | tr ' ' "$char"
  printf "${C_RESET}\n"
}

_header() {
  clear
  echo
  printf "${C_CYAN}${C_BOLD}"
  cat <<'BANNER'
     ██████╗    ██╗      ██████╗██╗     ██╗
    ██╔══██╗   ██║     ██╔════╝██║     ██║
    ███████║   ██║     ██║     ██║     ██║
    ██╔══██║   ██║     ██║     ██║     ██║
    ██║  ██║██╗███████╗╚██████╗███████╗██║
    ╚═╝  ╚═╝╚═╝╚══════╝ ╚═════╝╚══════╝╚═╝
BANNER
  printf "${C_RESET}"
  printf "${C_DIM}${C_GRAY}    Local AI CLI  ·  powered by Ollama${C_RESET}\n"
  echo
  _line "─" "$C_GRAY"
}

_badge() {
  local label="$1" value="$2" color="${3:-$C_CYAN}"
  printf "  ${C_DIM}${label}${C_RESET}  ${color}${C_BOLD}${value}${C_RESET}"
}

_status_bar() {
  local model="${SELECTED_MODEL:-—}"
  local agent="${SELECTED_AGENT:-—}"
  local conn_badge
  if [[ "$CONNECTION_MODE" == "external" ]]; then
    local conn_name="${ACTIVE_CONNECTION:-externe}"
    conn_badge="${C_BLUE}🌐 ${conn_name}${C_RESET}"
  else
    if _ollama_running; then
      conn_badge="${C_GREEN}● Ollama online${C_RESET}"
    else
      conn_badge="${C_RED}● Ollama offline${C_RESET}"
    fi
  fi
  echo
  _badge "MODEL" "$model" "$C_GREEN"
  printf "   "
  _badge "AGENT" "$agent" "$C_YELLOW"
  printf "   "
  printf "  ${C_DIM}CONN${C_RESET}  ${conn_badge}"
  echo
  _line "─" "$C_GRAY"
}

_info()   { printf "  ${C_CYAN}ℹ${C_RESET}  %s\n" "$1" }
_ok()     { printf "  ${C_GREEN}✔${C_RESET}  %s\n" "$1" }
_warn()   { printf "  ${C_YELLOW}⚠${C_RESET}  %s\n" "$1" }
_error()  { printf "  ${C_RED}✘${C_RESET}  %s\n" "$1" }
_prompt() { printf "  ${C_MAGENTA}❯${C_RESET}  ${C_WHITE}%s${C_RESET} " "$1" }

_spinner() {
  local pid=$1 msg="${2:-Génération en cours…}"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  ${C_CYAN}%s${C_RESET}  ${C_DIM}%s${C_RESET}   " "${frames[$((i % 10))]}" "$msg"
    ((i++))
    sleep 0.08
  done
  printf "\r\033[2K"
}

# ── Mémoire de session ────────────────────────────────────

save_session_state() {
  mkdir -p "$(dirname "$STATE_FILE")"
  printf "LAST_MODEL=%s\nLAST_AGENT=%s\n" "$SELECTED_MODEL" "$SELECTED_AGENT" > "$STATE_FILE"
}

load_session_state() {
  [[ -f "$STATE_FILE" ]] || return
  local last_model last_agent
  last_model=$(grep '^LAST_MODEL=' "$STATE_FILE" | cut -d= -f2-)
  last_agent=$(grep  '^LAST_AGENT=' "$STATE_FILE" | cut -d= -f2-)
  [[ -n "$last_model" ]] && SELECTED_MODEL="$last_model"
  [[ -n "$last_agent" ]] && SELECTED_AGENT="$last_agent"
}
# ── Configuration projet (extensions + dossiers exclus) ──────

_config_defaults() {
  CODE_EXTENSIONS=(php js ts jsx tsx vue py rb go rs java kt swift cs cpp c h css scss sass less html htm xml json yaml yml toml env md sh zsh bash)
  EXCLUDED_DIRS=(vendor node_modules .git dist build cache .cache .idea .vscode __pycache__ coverage)
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || return
  local line key val
  while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      CODE_EXTENSIONS)  eval "CODE_EXTENSIONS=($val)" ;;
      EXCLUDED_DIRS)    eval "EXCLUDED_DIRS=($val)" ;;
      CONNECTION_MODE)  CONNECTION_MODE="$val" ;;
      ACTIVE_CONNECTION) ACTIVE_CONNECTION="$val" ;;
    esac
  done < "$CONFIG_FILE"
}

save_config() {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  {
    echo "# AI-CLI config — extensions et dossiers exclus"
    echo "CODE_EXTENSIONS=${CODE_EXTENSIONS[*]}"
    echo "EXCLUDED_DIRS=${EXCLUDED_DIRS[*]}"
    echo "CONNECTION_MODE=$CONNECTION_MODE"
    echo "ACTIVE_CONNECTION=$ACTIVE_CONNECTION"
  } > "$CONFIG_FILE"
}



# ── Profils modèles (label + usages + agent associé) ─────
# Format fichier : MODEL_NAME|label|usage1,usage2,usage3|associated_agent

_profiles_init() {
  [[ -f "$PROFILES_FILE" ]] || touch "$PROFILES_FILE"
}

_profile_get() {
  # _profile_get <model> <field: label|usages|agent>
  local model="$1" field="$2"
  local line
  line=$(grep "^${model}|" "$PROFILES_FILE" 2>/dev/null | head -1)
  [[ -z "$line" ]] && echo "" && return
  case "$field" in
    label)  echo "$line" | cut -d'|' -f2 ;;
    usages) echo "$line" | cut -d'|' -f3 ;;
    agent)  echo "$line" | cut -d'|' -f4 ;;
  esac
}

_profile_set() {
  local model="$1" label="$2" usages="$3" agent="$4"
  _profiles_init
  # Supprime ligne existante puis réécrit
  local tmpfile; tmpfile=$(mktemp)
  grep -v "^${model}|" "$PROFILES_FILE" > "$tmpfile" 2>/dev/null || true
  echo "${model}|${label}|${usages}|${agent}" >> "$tmpfile"
  mv "$tmpfile" "$PROFILES_FILE"
}

_profile_delete() {
  local model="$1"
  local tmpfile; tmpfile=$(mktemp)
  grep -v "^${model}|" "$PROFILES_FILE" > "$tmpfile" 2>/dev/null || true
  mv "$tmpfile" "$PROFILES_FILE"
}

# Affiche une fiche profil pour un modèle
_profile_card() {
  local model="$1"
  local label usages agent
  label=$(_profile_get "$model" label)
  usages=$(_profile_get "$model" usages)
  agent=$(_profile_get "$model" agent)

  if [[ -n "$label" ]]; then
    printf "      ${C_BOLD}${C_WHITE}%s${C_RESET}\n" "$label"
    if [[ -n "$usages" ]]; then
      printf "      ${C_DIM}Utilisé pour :${C_RESET}\n"
      # Affiche chaque usage sur une ligne
      echo "$usages" | tr ',' '\n' | while IFS= read -r u; do
        [[ -n "$u" ]] && printf "        ${C_GRAY}·${C_RESET} ${C_DIM}%s${C_RESET}\n" "$u"
      done
    fi
    if [[ -n "$agent" ]]; then
      printf "      ${C_DIM}Agent associé :${C_RESET}  ${C_YELLOW}%s${C_RESET}\n" "$agent"
    fi
  else
    printf "      ${C_GRAY}${C_DIM}Aucun profil configuré${C_RESET}\n"
  fi
}

# ── Vérification Ollama ───────────────────────────────────

_ollama_running() {
  curl -sf "${OLLAMA_HOST}/api/tags" > /dev/null 2>&1
}

_require_ollama() {
  # En mode externe, pas besoin d'Ollama
  [[ "$CONNECTION_MODE" == "external" ]] && return 0
  _ollama_running && return 0
  _error "Ollama est hors ligne (${OLLAMA_HOST})"
  echo
  _info "Pour démarrer manuellement : ${C_DIM}ollama serve${C_RESET}"
  _prompt "Tenter de démarrer Ollama automatiquement ? (o/N) :"
  read -r ans
  if [[ "$ans" =~ ^[oO]$ ]]; then
    _info "Démarrage d'Ollama en arrière-plan…"
    ollama serve > /dev/null 2>&1 &
    local attempts=0
    while ! _ollama_running; do
      sleep 1
      ((attempts++))
      if [[ $attempts -ge 8 ]]; then
        _error "Timeout — Ollama ne répond pas. Vérifie l'installation."
        sleep 1.5
        return 1
      fi
    done
    _ok "Ollama démarré avec succès."
    sleep 0.6
    return 0
  fi
  return 1
}

# ── Gestion des modèles ───────────────────────────────────

_ollama_list_models() {
  curl -sf "${OLLAMA_HOST}/api/tags" \
    | grep -o '"name":"[^"]*"' \
    | cut -d'"' -f4
}

# Éditer le profil d'un modèle (label, usages, agent associé)
_edit_model_profile() {
  local model="$1"
  local cur_label cur_usages cur_agent

  cur_label=$(_profile_get "$model" label)
  cur_usages=$(_profile_get "$model" usages)
  cur_agent=$(_profile_get "$model" agent)

  # Lister les agents disponibles pour la sélection
  local agents=()
  for dir in "$AGENTS_DIR"/*/; do
    [[ -d "$dir" ]] && agents+=("$(basename "$dir")")
  done

  _header
  _status_bar
  printf "  ${C_BOLD}${C_WHITE}Éditer le profil de${C_RESET}  ${C_CYAN}%s${C_RESET}\n\n" "$model"

  # Label / rôle
  if [[ -n "$cur_label" ]]; then
    printf "  ${C_DIM}Label actuel :${C_RESET}  ${C_WHITE}%s${C_RESET}\n" "$cur_label"
  fi
  _prompt "Nouveau label ${C_DIM}(ex: Code lourd / refactorisation)${C_RESET} — Entrée pour garder :"
  read -r new_label
  [[ -z "$new_label" ]] && new_label="$cur_label"

  echo

  # Usages (liste CSV)
  if [[ -n "$cur_usages" ]]; then
    printf "  ${C_DIM}Usages actuels :${C_RESET}\n"
    echo "$cur_usages" | tr ',' '\n' | while IFS= read -r u; do
      [[ -n "$u" ]] && printf "    ${C_GRAY}·${C_RESET} %s\n" "$u"
    done
  fi
  _info "Entre les usages séparés par des virgules."
  _prompt "Usages ${C_DIM}(ex: Génération services Symfony,Refactorisation backend)${C_RESET} :"
  read -r new_usages
  [[ -z "$new_usages" ]] && new_usages="$cur_usages"

  echo

  # Agent associé
  local new_agent="$cur_agent"
  if [[ ${#agents[@]} -gt 0 ]]; then
    if [[ -n "$cur_agent" ]]; then
      printf "  ${C_DIM}Agent associé actuel :${C_RESET}  ${C_YELLOW}%s${C_RESET}\n" "$cur_agent"
    fi
    printf "  ${C_DIM}Agents disponibles :${C_RESET}\n\n"
    local i=1 marker
    for a in "${agents[@]}"; do
      marker="  "
      [[ "$a" == "$cur_agent" ]] && marker="${C_YELLOW}✔${C_RESET} "
      printf "  ${C_GRAY}%2d${C_RESET}  %b%s\n" "$i" "$marker" "$a"
      ((i++))
    done
    printf "  ${C_GRAY}%2d${C_RESET}  ${C_DIM}(aucun)${C_RESET}\n" "$i"
    echo
    _prompt "Numéro de l'agent à associer (Entrée pour garder) :"
    read -r achoice
    if [[ "$achoice" =~ ^[0-9]+$ ]]; then
      if [[ "$achoice" -ge 1 && "$achoice" -le "${#agents[@]}" ]]; then
        new_agent="${agents[$achoice]}"
      elif [[ "$achoice" -eq $((${#agents[@]} + 1)) ]]; then
        new_agent=""
      fi
    fi
  else
    _warn "Aucun agent disponible dans $AGENTS_DIR"
    echo
    _prompt "Nom de l'agent à associer (Entrée pour ignorer) :"
    read -r new_agent_raw
    [[ -n "$new_agent_raw" ]] && new_agent="$new_agent_raw"
  fi

  _profile_set "$model" "$new_label" "$new_usages" "$new_agent"
  echo
  _ok "Profil de ${C_CYAN}${model}${C_RESET} enregistré."

  # Proposer de charger le modèle + son agent associé
  if [[ -n "$new_agent" ]]; then
    _prompt "Charger ce modèle et son agent maintenant ? (o/N) :"
    read -r load_now
    if [[ "$load_now" =~ ^[oO]$ ]]; then
      SELECTED_MODEL="$model"
      SELECTED_AGENT="$new_agent"
      save_session_state
      _ok "Modèle : ${C_GREEN}${SELECTED_MODEL}${C_RESET}  Agent : ${C_YELLOW}${SELECTED_AGENT}${C_RESET}"
    fi
  fi
  sleep 1
}

manage_models() {
  _require_ollama || return
  _profiles_init

  # Toutes les locales déclarées UNE seule fois, hors boucle
  local installed=() m i action choice
  local active_marker label assoc_agent usages
  local new_model do_profile to_delete confirm

  while true; do
    _header
    _status_bar
    printf "  ${C_BOLD}${C_WHITE}Gestion des modèles${C_RESET}\n\n"

    # Recharge la liste à chaque tour
    installed=()
    if [[ "$CONNECTION_MODE" == "external" ]]; then
      # Essaie de lister les modèles via /v1/models (OpenAI-compatible)
      while IFS= read -r m; do
        [[ -n "$m" ]] && installed+=("$m")
      done < <(curl -sf -H "Authorization: Bearer ${EXTERNAL_API_KEY}" \
        "${EXTERNAL_URL}/v1/models" 2>/dev/null \
        | python3 -c "
import sys, json
try:
  data = json.load(sys.stdin)
  for m in data.get('data', []):
    print(m.get('id',''))
except: pass
" 2>/dev/null | sort)
    else
      while IFS= read -r m; do
        [[ -n "$m" ]] && installed+=("$m")
      done < <(_ollama_list_models | sort)
    fi

    if [[ ${#installed[@]} -eq 0 ]]; then
      if [[ "$CONNECTION_MODE" == "external" ]]; then
        _warn "Impossible de lister les modèles — configure manuellement avec ${C_GRAY}m${C_RESET}"
      else
        _warn "Aucun modèle installé localement."
      fi
    else
      printf "  ${C_DIM}Modèles installés :${C_RESET}\n\n"
      i=1
      for m in "${installed[@]}"; do
        active_marker="  "
        [[ "$m" == "$SELECTED_MODEL" ]] && active_marker="${C_GREEN}✔${C_RESET} "

        label=$(_profile_get "$m" label)
        assoc_agent=$(_profile_get "$m" agent)

        # Ligne principale
        printf "  ${C_GRAY}%2d${C_RESET}  %b${C_WHITE}%s${C_RESET}" "$i" "$active_marker" "$m"
        [[ -n "$label" ]] && printf "  ${C_DIM}—  %s${C_RESET}" "$label"
        [[ -n "$assoc_agent" ]] && printf "  ${C_YELLOW}[%s]${C_RESET}" "$assoc_agent"
        echo

        # Usages si présents
        usages=$(_profile_get "$m" usages)
        if [[ -n "$usages" ]]; then
          echo "$usages" | tr ',' '\n' | while IFS= read -r u; do
            [[ -n "$u" ]] && printf "        ${C_GRAY}·${C_RESET} ${C_DIM}%s${C_RESET}\n" "$u"
          done
        fi
        echo

        ((i++))
      done
    fi

    _line "╌" "$C_GRAY"
    printf "  ${C_GRAY}s${C_RESET}  Sélectionner un modèle ${C_DIM}(charge aussi son agent associé)${C_RESET}\n"
    printf "  ${C_GRAY}e${C_RESET}  Éditer le profil d'un modèle ${C_DIM}(label · usages · agent)${C_RESET}\n"
    if [[ "$CONNECTION_MODE" == "external" ]]; then
      printf "  ${C_GRAY}m${C_RESET}  Définir le modèle manuellement ${C_DIM}(nom exact du modèle distant)${C_RESET}\n"
    else
      printf "  ${C_GRAY}a${C_RESET}  Ajouter un modèle ${C_DIM}(ollama pull)${C_RESET}\n"
      printf "  ${C_GRAY}d${C_RESET}  Supprimer un modèle\n"
    fi
    printf "  ${C_GRAY}r${C_RESET}  Rafraîchir\n"
    printf "  ${C_GRAY}q${C_RESET}  Retour au menu\n"
    echo
    _prompt "Action :"
    read -r action || break

    case "$action" in

      s|S)
        if [[ ${#installed[@]} -eq 0 ]]; then
          _warn "Aucun modèle disponible."; sleep 1; continue
        fi
        echo
        _prompt "Numéro du modèle :"
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#installed[@]}" ]]; then
          SELECTED_MODEL="${installed[$choice]}"
          # Charger automatiquement l'agent associé si défini
          local assoc; assoc=$(_profile_get "$SELECTED_MODEL" agent)
          if [[ -n "$assoc" && -d "$AGENTS_DIR/$assoc" ]]; then
            SELECTED_AGENT="$assoc"
            _ok "Modèle : ${C_GREEN}${SELECTED_MODEL}${C_RESET}"
            _ok "Agent associé chargé : ${C_YELLOW}${SELECTED_AGENT}${C_RESET}"
          else
            _ok "Modèle actif : ${C_GREEN}${SELECTED_MODEL}${C_RESET}"
          fi
          save_session_state
        else
          _error "Choix invalide."
        fi
        sleep 1
        ;;

      e|E)
        if [[ ${#installed[@]} -eq 0 ]]; then
          _warn "Aucun modèle disponible."; sleep 1; continue
        fi
        echo
        _prompt "Numéro du modèle à éditer :"
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#installed[@]}" ]]; then
          _edit_model_profile "${installed[$choice]}"
        else
          _error "Choix invalide."; sleep 0.8
        fi
        ;;

      a|A)
        if [[ "$CONNECTION_MODE" == "external" ]]; then
          _warn "Pull non disponible en mode externe. Utilise ${C_GRAY}m${C_RESET} pour définir le modèle manuellement."
          sleep 1.5; continue
        fi
        echo
        _info "Exemples : llama3, gemma:7b, phi3, mistral, codellama"
        _prompt "Nom du modèle à télécharger :"
        read -r new_model
        [[ -z "$new_model" ]] && continue
        echo
        _info "Pull de ${C_CYAN}${new_model}${C_RESET} — cela peut prendre plusieurs minutes…"
        _line "╌" "$C_GRAY"
        if OLLAMA_HOST="$OLLAMA_HOST" ollama pull "$new_model"; then
          echo
          _ok "Modèle ${C_GREEN}${new_model}${C_RESET} installé."
          _prompt "Configurer le profil de ce modèle maintenant ? (o/N) :"
          read -r do_profile
          [[ "$do_profile" =~ ^[oO]$ ]] && _edit_model_profile "$new_model"
        else
          _error "Échec du pull pour « ${new_model} »."
        fi
        sleep 1
        ;;

      d|D)
        if [[ "$CONNECTION_MODE" == "external" ]]; then
          _warn "Suppression non disponible en mode externe."
          sleep 1.2; continue
        fi
        if [[ ${#installed[@]} -eq 0 ]]; then
          _warn "Aucun modèle à supprimer."; sleep 1; continue
        fi
        echo
        _prompt "Numéro du modèle à supprimer :"
        read -r choice
        if ! [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#installed[@]}" ]]; then
          _error "Choix invalide."; sleep 0.8; continue
        fi
        local to_delete="${installed[$choice]}"
        echo
        _prompt "Confirmer la suppression de ${C_RED}${to_delete}${C_RESET} ? (o/N) :"
        read -r confirm
        if [[ "$confirm" =~ ^[oO]$ ]]; then
          if OLLAMA_HOST="$OLLAMA_HOST" ollama rm "$to_delete"; then
            _profile_delete "$to_delete"
            _ok "Modèle et profil de ${to_delete} supprimés."
            [[ "$SELECTED_MODEL" == "$to_delete" ]] && SELECTED_MODEL="" && save_session_state
          else
            _error "Échec de la suppression."
          fi
        else
          _info "Annulé."
        fi
        sleep 0.8
        ;;

      m|M)
        # Saisie manuelle du modèle (mode externe ou fallback)
        echo
        _info "Entre le nom exact du modèle tel qu'il est exposé par le serveur distant."
        _prompt "Nom du modèle :"
        read -r new_model
        [[ -z "$new_model" ]] && continue
        SELECTED_MODEL="$new_model"
        save_session_state
        _ok "Modèle actif : ${C_GREEN}${SELECTED_MODEL}${C_RESET}"
        sleep 1
        ;;

      r|R) continue ;;
      q|Q) break ;;
      *) _error "Action invalide."; sleep 0.5 ;;
    esac
  done
}

# ── Agents ────────────────────────────────────────────────

_list_agents() {
  local agents=()
  for dir in "$AGENTS_DIR"/*/; do
    [[ -d "$dir" ]] && agents+=("$(basename "$dir")")
  done
  echo "${agents[@]}"
}

select_agent() {
  _header
  _status_bar
  printf "  ${C_BOLD}${C_WHITE}Choisir un agent${C_RESET}\n\n"

  local agents=()
  for dir in "$AGENTS_DIR"/*/; do
    [[ -d "$dir" ]] && agents+=("$(basename "$dir")")
  done

  if [[ ${#agents[@]} -eq 0 ]]; then
    _warn "Aucun agent trouvé dans ${AGENTS_DIR}"
    sleep 1.2; return
  fi

  local i=1 marker
  for a in "${agents[@]}"; do
    marker="  "
    [[ "$a" == "$SELECTED_AGENT" ]] && marker="${C_YELLOW}✔${C_RESET} "
    printf "  ${C_GRAY}%2d${C_RESET}  %b%s\n" "$i" "$marker" "$a"
    ((i++))
  done

  echo
  _prompt "Numéro de l'agent :"
  read -r choice
  if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#agents[@]}" ]]; then
    SELECTED_AGENT="${agents[$choice]}"
    save_session_state
    _ok "Agent actif : ${C_YELLOW}${SELECTED_AGENT}${C_RESET}"
  else
    _error "Choix invalide."
  fi
  sleep 0.8
}

# ── Édition d'un agent ────────────────────────────────────

edit_agent() {
  _header
  _status_bar
  printf "  ${C_BOLD}${C_WHITE}Éditer un agent${C_RESET}\n\n"

  local agents=()
  for dir in "$AGENTS_DIR"/*/; do
    [[ -d "$dir" ]] && agents+=("$(basename "$dir")")
  done

  if [[ ${#agents[@]} -eq 0 ]]; then
    _warn "Aucun agent disponible."
    echo
    _prompt "Créer un nouvel agent ? (o/N) :"
    read -r ans
    [[ "$ans" =~ ^[oO]$ ]] || return
    _create_agent
    return
  fi

  local i=1 a
  for a in "${agents[@]}"; do
    printf "  ${C_GRAY}%2d${C_RESET}  %s\n" "$i" "$a"
    ((i++))
  done
  printf "  ${C_GRAY}%2d${C_RESET}  ${C_GREEN}+ Créer un nouvel agent${C_RESET}\n" "$i"
  echo
  _prompt "Choix :"
  read -r choice

  if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#agents[@]}" ]]; then
    _edit_agent_files "${agents[$choice]}"
  elif [[ "$choice" -eq $((${#agents[@]} + 1)) ]]; then
    _create_agent
  else
    _error "Choix invalide."; sleep 0.8
  fi
}

_create_agent() {
  echo
  _prompt "Nom du nouvel agent (sans espaces) :"
  read -r agent_name
  [[ -z "$agent_name" ]] && return
  agent_name="${agent_name// /_}"
  local agent_dir="$AGENTS_DIR/$agent_name"
  if [[ -d "$agent_dir" ]]; then
    _warn "Un agent avec ce nom existe déjà."; sleep 1; return
  fi
  mkdir -p "$agent_dir"
  _ok "Dossier créé : ${C_DIM}${agent_dir}${C_RESET}"
  _edit_agent_files "$agent_name"
}

_edit_agent_files() {
  local agent_name="$1"
  local agent_dir="$AGENTS_DIR/$agent_name"
  local files=() f action fchoice i linecount content fname fpath line
  local target_file editor to_rm confirm

  while true; do
    _header
    _status_bar
    printf "  ${C_BOLD}${C_WHITE}Agent :${C_RESET}  ${C_YELLOW}%s${C_RESET}\n\n" "$agent_name"

    files=()
    for f in "$agent_dir"/*.txt; do
      [[ -f "$f" ]] && files+=("$(basename "$f")")
    done

    if [[ ${#files[@]} -eq 0 ]]; then
      _warn "Aucun fichier .txt dans cet agent."
    else
      printf "  ${C_DIM}Fichiers du prompt système :${C_RESET}\n\n"
      i=1
      for f in "${files[@]}"; do
        linecount=$(wc -l < "$agent_dir/$f" 2>/dev/null || echo 0)
        printf "  ${C_GRAY}%2d${C_RESET}  ${C_WHITE}%s${C_RESET}  ${C_DIM}(%s lignes)${C_RESET}\n" "$i" "$f" "$linecount"
        ((i++))
      done
    fi

    echo
    _line "╌" "$C_GRAY"
    printf "  ${C_GRAY}n${C_RESET}  Nouveau fichier .txt\n"
    printf "  ${C_GRAY}e${C_RESET}  Éditer un fichier existant\n"
    printf "  ${C_GRAY}v${C_RESET}  Voir le contenu d'un fichier\n"
    printf "  ${C_GRAY}x${C_RESET}  Supprimer un fichier\n"
    printf "  ${C_GRAY}q${C_RESET}  Retour\n"
    echo
    _prompt "Action :"
    read -r action || break

    case "$action" in

      n|N)
        echo
        _prompt "Nom du fichier (sans .txt) :"
        read -r fname
        [[ -z "$fname" ]] && continue
        local fpath="$agent_dir/${fname}.txt"
        if [[ -f "$fpath" ]]; then
          _warn "Ce fichier existe déjà. Utilise 'e' pour l'éditer."; sleep 1; continue
        fi
        printf "" > "$fpath"
        _ok "Fichier créé : ${C_DIM}${fname}.txt${C_RESET}"
        echo
        _info "Entre le contenu du prompt. Termine avec une ligne contenant uniquement ${C_RED}EOF${C_RESET}"
        echo
        local content=""
        while IFS= read -r line; do
          [[ "$line" == "EOF" ]] && break
          content+="$line"$'\n'
        done
        printf '%s' "$content" > "$fpath"
        _ok "Contenu enregistré ($(echo "$content" | wc -l) lignes)."
        sleep 0.8
        ;;

      e|E)
        if [[ ${#files[@]} -eq 0 ]]; then
          _warn "Aucun fichier à éditer."; sleep 1; continue
        fi
        echo
        _prompt "Numéro du fichier à éditer :"
        read -r fchoice
        if ! [[ "$fchoice" =~ ^[0-9]+$ && "$fchoice" -ge 1 && "$fchoice" -le "${#files[@]}" ]]; then
          _error "Choix invalide."; sleep 0.8; continue
        fi
        local target_file="$agent_dir/${files[$fchoice]}"
        # Essayer d'ouvrir dans un éditeur
        local editor="${EDITOR:-}"
        if [[ -z "$editor" ]]; then
          for ed in nano vim vi; do
            command -v "$ed" > /dev/null 2>&1 && editor="$ed" && break
          done
        fi
        if [[ -n "$editor" ]]; then
          "$editor" "$target_file"
          _ok "Fichier sauvegardé."
        else
          _warn "Aucun éditeur trouvé. Définis la variable EDITOR."
          _info "Ex: export EDITOR=nano"
        fi
        sleep 0.8
        ;;

      v|V)
        if [[ ${#files[@]} -eq 0 ]]; then
          _warn "Aucun fichier."; sleep 1; continue
        fi
        echo
        _prompt "Numéro du fichier à voir :"
        read -r fchoice
        if [[ "$fchoice" =~ ^[0-9]+$ && "$fchoice" -ge 1 && "$fchoice" -le "${#files[@]}" ]]; then
          echo
          _line "─" "$C_GRAY"
          cat "$agent_dir/${files[$fchoice]}" | sed 's/^/    /'
          _line "─" "$C_GRAY"
          echo
          _prompt "Entrée pour continuer…"
          read -r
        else
          _error "Choix invalide."; sleep 0.8
        fi
        ;;

      x|X)
        if [[ ${#files[@]} -eq 0 ]]; then
          _warn "Aucun fichier."; sleep 1; continue
        fi
        echo
        _prompt "Numéro du fichier à supprimer :"
        read -r fchoice
        if ! [[ "$fchoice" =~ ^[0-9]+$ && "$fchoice" -ge 1 && "$fchoice" -le "${#files[@]}" ]]; then
          _error "Choix invalide."; sleep 0.8; continue
        fi
        local to_rm="${files[$fchoice]}"
        _prompt "Supprimer ${C_RED}${to_rm}${C_RESET} ? (o/N) :"
        read -r confirm
        if [[ "$confirm" =~ ^[oO]$ ]]; then
          rm "$agent_dir/$to_rm"
          _ok "Fichier supprimé."
        else
          _info "Annulé."
        fi
        sleep 0.8
        ;;

      q|Q) break ;;
      *) _error "Action invalide."; sleep 0.5 ;;
    esac
  done
}

# ── Système prompt ────────────────────────────────────────

build_system_prompt() {
  local agent_dir="$AGENTS_DIR/$SELECTED_AGENT"
  SYSTEM_PROMPT=""
  if [[ ! -d "$agent_dir" ]]; then
    _error "Dossier agent introuvable : $agent_dir"
    return 1
  fi
  for file in "$agent_dir"/*.txt; do
    [[ -f "$file" ]] || continue
    SYSTEM_PROMPT+="$(printf '\n--- %s ---\n' "$(basename "$file")")"$'\n'
    SYSTEM_PROMPT+="$(cat "$file")"$'\n'
  done

  # Instruction de format pour les modifications de fichiers
  SYSTEM_PROMPT+=$'\n'
  SYSTEM_PROMPT+="--- instructions de modification de fichiers ---"$'\n'
  SYSTEM_PROMPT+="Quand tu proposes de modifier un fichier existant, retourne le fichier COMPLET"$'\n'
  SYSTEM_PROMPT+="en utilisant exactement ce format (ne jamais omettre les balises) :"$'\n'
  SYSTEM_PROMPT+=$'\n'
  SYSTEM_PROMPT+="<<<FILE:chemin/relatif/du/fichier>>>"$'\n'
  SYSTEM_PROMPT+="...contenu complet du fichier modifié..."$'\n'
  SYSTEM_PROMPT+="<<<END>>>"$'\n'
  SYSTEM_PROMPT+=$'\n'
  SYSTEM_PROMPT+="Tu peux proposer plusieurs fichiers à la suite."$'\n'
  SYSTEM_PROMPT+="En dehors de ces blocs, explique normalement tes modifications."$'\n'
}

# ── Logging ───────────────────────────────────────────────

init_logging() {
  local today; today=$(date +"%Y-%m-%d")
  local day_dir="$LOGS_DIR/$today"
  mkdir -p "$day_dir"
  local agent_name="${SELECTED_AGENT:-no-agent}"
  local count
  count=$(ls "$day_dir" 2>/dev/null | grep -c "^${agent_name}_session-" || echo 0)
  SESSION_ID=$(printf "%02d" $((count + 1)))
  LOG_FILE="$day_dir/${agent_name}_session-${SESSION_ID}.log"
  touch "$LOG_FILE"
  {
    echo "# AI-CLI Session"
    echo "# Date    : $(date)"
    echo "# Model   : $SELECTED_MODEL"
    echo "# Agent   : $SELECTED_AGENT"
    echo "# Session : $SESSION_ID"
    echo "# ────────────────────────────────────────"
  } >> "$LOG_FILE"
}

log_entry() {
  printf "[%s] %s:\n%s\n\n" "$(date +"%Y-%m-%d %H:%M:%S")" "$1" "$2" >> "$LOG_FILE"
}

# ── Appel modèle (Ollama local ou serveur externe) ────────

call_model_clean() {
  local prompt="$1"
  local json_payload

  if [[ "$CONNECTION_MODE" == "external" ]]; then
    # API OpenAI-compatible (/v1/chat/completions)
    json_payload=$(python3 -c "
import sys, json
print(json.dumps({'model': sys.argv[1], 'messages': [{'role': 'user', 'content': sys.argv[2]}], 'stream': False}))
" "$SELECTED_MODEL" "$prompt" 2>/dev/null)

    local curl_args=(-sf -X POST "${EXTERNAL_URL}/v1/chat/completions"
      -H "Content-Type: application/json"
      -d "$json_payload")
    [[ -n "$EXTERNAL_API_KEY" ]] && curl_args+=(-H "Authorization: Bearer ${EXTERNAL_API_KEY}")

    curl "${curl_args[@]}" \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data['choices'][0]['message']['content'])
" 2>/dev/null
  else
    # API Ollama locale (/api/generate)
    json_payload=$(python3 -c "
import sys, json
print(json.dumps({'model': sys.argv[1], 'prompt': sys.argv[2], 'stream': False}))
" "$SELECTED_MODEL" "$prompt" 2>/dev/null)

    curl -sf \
      -X POST "${OLLAMA_HOST}/api/generate" \
      -H "Content-Type: application/json" \
      -d "$json_payload" \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('response', ''))
" 2>/dev/null
  fi
}


# ── Contexte fichiers (@mention et @?recherche) ───────────────

# Vérifie si une extension est reconnue comme code
_is_code_file() {
  local file="$1"
  local ext="${file##*.}"
  for e in "${CODE_EXTENSIONS[@]}"; do
    [[ "$ext" == "$e" ]] && return 0
  done
  return 1
}

# Construit les args find pour exclure les dossiers ignorés
_find_exclude_args() {
  local args=()
  for d in "${EXCLUDED_DIRS[@]}"; do
    args+=(-path "*/$d" -prune -o)
  done
  echo "${args[@]}"
}

# Recherche un fichier par nom exact (récursif, dossiers exclus)
_find_file_by_name() {
  local name="$1" base="${2:-$PROJECT_DIR}"
  [[ -z "$base" ]] && base="$PWD"
  local exclude_args
  exclude_args=($(_find_exclude_args))
  find "$base" "${exclude_args[@]}" -type f -name "$name" -print 2>/dev/null | head -5
}

# Recherche intelligente : trouve les fichiers contenant un terme
_find_file_by_content() {
  local term="$1" base="${2:-$PROJECT_DIR}"
  [[ -z "$base" ]] && base="$PWD"
  local exclude_args
  exclude_args=($(_find_exclude_args))
  # Cherche dans les fichiers code seulement
  find "$base" "${exclude_args[@]}" -type f -print 2>/dev/null     | while IFS= read -r f; do
        _is_code_file "$f" && echo "$f"
      done     | xargs grep -l "$term" 2>/dev/null     | head -5
}

# Lit un fichier et retourne son contenu formaté pour le prompt
_file_to_context() {
  local filepath="$1"
  if [[ ! -f "$filepath" ]]; then
    printf "[ERREUR: fichier introuvable : %s]
" "$filepath"
    return
  fi
  local size
  size=$(wc -c < "$filepath" 2>/dev/null || echo 0)
  # Limite à 80ko par fichier pour ne pas saturer le contexte
  if [[ $size -gt 81920 ]]; then
    printf "[AVERTISSEMENT: %s tronqué à 80ko]
" "$filepath"
    head -c 81920 "$filepath"
  else
    cat "$filepath"
  fi
}

# Parse le message, résout les @mentions, retourne le contexte injecté
# Modifie CONTEXT_BLOCK (variable globale temporaire) et CLEAN_INPUT
CONTEXT_BLOCK=""
CLEAN_INPUT=""

resolve_context() {
  # Toutes les locales déclarées ici — évite le conflit de type zsh dans les boucles
  local input="$1" base tokens token
  local term found_files fpath rel name dirpath dir_ctx recursive mode_label
  CONTEXT_BLOCK=""
  CLEAN_INPUT="$input"

  base="${PROJECT_DIR:-$PWD}"
  local injected=()

  # Extraire tous les tokens @xxx ou @?xxx
  tokens=$(echo "$input" | grep -oE '@\?[^ ]+|@[^ ]+' | sort -u)

  [[ -z "$tokens" ]] && return

  while IFS= read -r token; do
    [[ -z "$token" ]] && continue

    if [[ "$token" == @\?* ]]; then
      # ── Recherche intelligente @?terme ──────────────────────
      term="${token#@\?}"
      printf "  ${C_CYAN}⌕${C_RESET}  Recherche intelligente pour ${C_WHITE}%s${C_RESET}…
" "$term" >&2

      found_files=$(_find_file_by_content "$term" "$base")

      if [[ -z "$found_files" ]]; then
        printf "  ${C_YELLOW}⚠${C_RESET}  Aucun fichier trouvé contenant « %s »
" "$term" >&2
        continue
      fi

      while IFS= read -r fpath; do
        [[ -z "$fpath" ]] && continue
        rel="${fpath#$base/}"
        printf "  ${C_GREEN}✔${C_RESET}  Injecté ${C_DIM}%s${C_RESET}
" "$rel" >&2
        CONTEXT_BLOCK+="$(printf '
=== FICHIER: %s ===
' "$rel")"
        CONTEXT_BLOCK+=$'
'
        CONTEXT_BLOCK+="$(_file_to_context "$fpath")"
        CONTEXT_BLOCK+=$'
'
        injected+=("$rel")
      done <<< "$found_files"

      # Retirer le token du message
      CLEAN_INPUT="${CLEAN_INPUT//$token/}"

    else
      # ── Mention directe @fichier.ext ────────────────────────
      name="${token#@}"
      printf "  ${C_CYAN}⌕${C_RESET}  Recherche de ${C_WHITE}%s${C_RESET}…
" "$name" >&2

      # Essai 1 : chemin absolu ou relatif direct
      fpath=""
      if [[ -f "$name" ]]; then
        fpath="$name"
      elif [[ -f "$base/$name" ]]; then
        fpath="$base/$name"
      else
        # Essai 2 : recherche par nom de fichier récursive
        fpath=$(_find_file_by_name "$name" "$base" | head -1)
      fi

      if [[ -z "$fpath" ]]; then
        printf "  ${C_YELLOW}⚠${C_RESET}  Fichier introuvable : %s
" "$name" >&2
        continue
      fi

      rel="${fpath#$base/}"
      printf "  ${C_GREEN}✔${C_RESET}  Injecté ${C_DIM}%s${C_RESET}
" "$rel" >&2
      CONTEXT_BLOCK+="$(printf '
=== FICHIER: %s ===
' "$rel")"
      CONTEXT_BLOCK+=$'
'
      CONTEXT_BLOCK+="$(_file_to_context "$fpath")"
      CONTEXT_BLOCK+=$'
'
      injected+=("$rel")

      # Retirer le token du message
      CLEAN_INPUT="${CLEAN_INPUT//$token/}"
    fi

  done <<< "$tokens"

  # Nettoyer les espaces superflus dans CLEAN_INPUT
  CLEAN_INPUT=$(echo "$CLEAN_INPUT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
}


# ── Application de modifications de fichiers ─────────────────

# Vérifie si la réponse contient des blocs <<<FILE:...>>>
_has_file_patches() {
  echo "$1" | grep -q '<<<FILE:'
}

# Parse et propose l'application de chaque bloc FILE
apply_file_patches() {
  local response="$1"
  local base="${PROJECT_DIR:-$PWD}"

  # Extraire les noms de fichiers proposés
  local filepaths=()
  while IFS= read -r fp; do
    [[ -n "$fp" ]] && filepaths+=("$fp")
  done < <(echo "$response" | grep -oE '<<<FILE:[^>]+>>>' | sed 's/<<<FILE://;s/>>>//')

  [[ ${#filepaths[@]} -eq 0 ]] && return

  echo
  _line "─" "$C_YELLOW"
  printf "  ${C_YELLOW}${C_BOLD}⚡ Modifications proposées${C_RESET}  ${C_DIM}(%d fichier(s))${C_RESET}\n" "${#filepaths[@]}"
  _line "─" "$C_YELLOW"
  echo

  local fp
  for fp in "${filepaths[@]}"; do
    local full_path="$base/$fp"
    # Extraire le contenu entre <<<FILE:fp>>> et <<<END>>>
    local new_content
    # Extraction robuste avec python3 — évite les problèmes de regex awk/sed
    new_content=$(printf '%s' "$response" | python3 -c "
import sys
data = sys.stdin.read()
marker = '<<<FILE:' + sys.argv[1] + '>>>'
end    = '<<<END>>>'
start  = data.find(marker)
if start == -1: sys.exit(0)
start  = data.find('\n', start) + 1
stop   = data.find(end, start)
if stop == -1: stop = len(data)
# Retirer la dernière newline avant <<<END>>>
block = data[start:stop]
if block.endswith('\n'): block = block[:-1]
print(block, end='')
" "$fp" 2>/dev/null)

    printf "  ${C_CYAN}${C_BOLD}%s${C_RESET}\n" "$fp"

    # Afficher le diff si le fichier existe
    if [[ -f "$full_path" ]]; then
      local diff_out
      diff_out=$(diff --color=never -u "$full_path" <(echo "$new_content") 2>/dev/null)
      if [[ -z "$diff_out" ]]; then
        printf "  ${C_DIM}(aucun changement détecté)${C_RESET}\n\n"
        continue
      fi
      echo
      # Afficher le diff avec coloration manuelle
      echo "$diff_out" | tail -n +3 | while IFS= read -r dline; do
        case "${dline:0:1}" in
          +) printf "    ${C_GREEN}%s${C_RESET}\n" "$dline" ;;
          -) printf "    ${C_RED}%s${C_RESET}\n" "$dline" ;;
          @) printf "    ${C_CYAN}%s${C_RESET}\n" "$dline" ;;
          *) printf "    ${C_DIM}%s${C_RESET}\n" "$dline" ;;
        esac
      done
      echo
    else
      printf "  ${C_DIM}(nouveau fichier — %d lignes)${C_RESET}\n\n" "$(echo "$new_content" | wc -l)"
    fi

    _prompt "Appliquer ${C_WHITE}${fp}${C_RESET} ? ${C_DIM}[o]ui  [n]on  [v]oir complet${C_RESET} :"
    read -r answer

    # Si v : afficher le contenu complet puis redemander
    if [[ "$answer" =~ ^[vV]$ ]]; then
      echo
      _line "╌" "$C_GRAY"
      echo "$new_content" | sed 's/^/    /'
      _line "╌" "$C_GRAY"
      echo
      _prompt "Appliquer ${C_WHITE}${fp}${C_RESET} ? ${C_DIM}[o]ui  [n]on${C_RESET} :"
      read -r answer
    fi

    if [[ "$answer" =~ ^[oO]$ ]]; then
      if [[ -z "$new_content" ]]; then
        _error "Contenu extrait vide — rien écrit."
        continue
      fi
      mkdir -p "$(dirname "$full_path")"
      if [[ -f "$full_path" ]]; then
        cp "$full_path" "${full_path}.bak"
        printf "  ${C_DIM}Sauvegarde → %s.bak${C_RESET}\n" "$fp"
      fi
      printf '%s' "$new_content" > "$full_path"
      local written
      written=$(wc -c < "$full_path")
      _ok "Fichier appliqué : ${C_GREEN}${fp}${C_RESET}  ${C_DIM}(${written} octets)${C_RESET}"
    else
      _info "Ignoré : $fp"
    fi
    echo
  done

  _line "─" "$C_GRAY"
  echo
}


# ── Affichage réponse ────────────────────────────────────────

_render_response() {
  # Filtre les blocs FILE bruts, indente simplement
  printf '%s\n' "$1" | awk '
    /<<<FILE:/{skip=1; next}
    /<<<END>>>/ && skip {skip=0; next}
    !skip {print}
  ' | sed 's/^/    /'
}


# ── Session interactive ───────────────────────────────────

interactive_session() {
  if [[ -z "$SELECTED_MODEL" ]]; then
    _error "Aucun modèle sélectionné → option 3 pour en choisir un."; sleep 1.5; return
  fi
  if [[ -z "$SELECTED_AGENT" ]]; then
    _error "Aucun agent sélectionné → option 4 pour en choisir un."; sleep 1.5; return
  fi
  _require_ollama || return
  build_system_prompt || return
  init_logging

  local session_label user_input payload model_response pid
  session_label=$(_profile_get "$SELECTED_MODEL" label)

  _header
  _status_bar
  [[ -n "$session_label" ]] && printf "  ${C_DIM}Rôle :${C_RESET}  ${C_WHITE}%s${C_RESET}\n" "$session_label"

  printf "  ${C_BOLD}${C_WHITE}Session interactive${C_RESET}  "
  printf "${C_DIM}(tape ${C_RESET}${C_RED}exit${C_RESET}${C_DIM} pour quitter)${C_RESET}\n"
  _line "─" "$C_GRAY"
  echo
  printf "  ${C_DIM}Contexte fichiers :${C_RESET}\n"
  printf "  ${C_GRAY}@fichier.php${C_RESET}          ${C_DIM}Injecte un fichier par nom${C_RESET}\n"
  printf "  ${C_GRAY}@src/Services/Mail.php${C_RESET} ${C_DIM}Injecte un fichier par chemin relatif${C_RESET}\n"
  printf "  ${C_GRAY}@?MaClasse${C_RESET}            ${C_DIM}Recherche intelligente par nom de classe/fonction${C_RESET}\n"
  printf "  ${C_DIM}Combinaisons :${C_RESET}\n"
  printf "  ${C_GRAY}refactorise @?PaymentService en utilisant @?MailerInterface${C_RESET}\n"
  printf "  ${C_GRAY}explique @UserController.php${C_RESET}\n"
  echo
  _line "╌" "$C_GRAY"
  echo

  while true; do
    printf "  ${C_GREEN}you${C_RESET}  ${C_GRAY}❯${C_RESET}  "
    read -r user_input || break
    [[ "$user_input" == "exit" ]] && break
    [[ -z "$user_input" ]] && continue

    # Résoudre les @mentions et @?recherches
    if [[ "$user_input" == *"@"* ]]; then
      echo
      resolve_context "$user_input"
      user_input="$CLEAN_INPUT"
      echo
    fi

    log_entry "USER" "$user_input"

    if [[ -n "$CONTEXT_BLOCK" ]]; then
      payload="$SYSTEM_PROMPT

Contexte — fichiers du projet :
$CONTEXT_BLOCK

User:
$user_input"
    else
      payload="$SYSTEM_PROMPT
User:
$user_input"
    fi

    call_model_clean "$payload" > /tmp/_ai_cli_resp.$$ 2>&1 &
    pid=$!
    _spinner $pid
    wait $pid
    model_response=$(cat /tmp/_ai_cli_resp.$$)
    rm -f /tmp/_ai_cli_resp.$$

    echo
    printf "  ${C_CYAN}${C_BOLD}${SELECTED_MODEL}${C_RESET}  ${C_GRAY}❯${C_RESET}\n\n"
    # Afficher la réponse avec pretty-print (sans blocs FILE, sans ```)
    _render_response "$model_response"
    echo
    _line "╌" "$C_GRAY"
    echo

    log_entry "MODEL" "$model_response"

    # Proposer l'application si des blocs FILE sont présents
    if _has_file_patches "$model_response"; then
      apply_file_patches "$model_response"
    fi
  done

  _ok "Session terminée  ·  log : ${C_DIM}${LOG_FILE}${C_RESET}"
  sleep 1
}

# ── One-shot ──────────────────────────────────────────────

one_shot_mode() {
  if [[ -z "$SELECTED_MODEL" ]]; then
    _error "Aucun modèle sélectionné."; sleep 1.5; return
  fi
  if [[ -z "$SELECTED_AGENT" ]]; then
    _error "Aucun agent sélectionné."; sleep 1.5; return
  fi
  _require_ollama || return
  build_system_prompt || return
  init_logging

  _header
  _status_bar
  printf "  ${C_BOLD}${C_WHITE}Mode one-shot${C_RESET}\n\n"

  _prompt "Question :"
  read -r user_input
  [[ -z "$user_input" ]] && return

  # Résoudre les @mentions et @?recherches
  if [[ "$user_input" == *"@"* ]]; then
    echo
    resolve_context "$user_input"
    user_input="$CLEAN_INPUT"
    echo
  fi

  log_entry "USER" "$user_input"

  local payload
  if [[ -n "$CONTEXT_BLOCK" ]]; then
    payload="$SYSTEM_PROMPT

Contexte — fichiers du projet :
$CONTEXT_BLOCK

User:
$user_input"
  else
    payload="$SYSTEM_PROMPT
User:
$user_input"
  fi

  echo
  local model_response
  call_model_clean "$payload" > /tmp/_ai_cli_resp.$$ 2>&1 &
  local pid=$!
  _spinner $pid
  wait $pid
  model_response=$(cat /tmp/_ai_cli_resp.$$)
  rm -f /tmp/_ai_cli_resp.$$

  printf "  ${C_CYAN}${C_BOLD}${SELECTED_MODEL}${C_RESET}  ${C_GRAY}❯${C_RESET}\n\n"
  echo "$model_response" | sed 's/^/    /'
  echo
  _line "─" "$C_GRAY"
  log_entry "MODEL" "$model_response"
  _ok "Log : ${C_DIM}${LOG_FILE}${C_RESET}"
  echo
  _prompt "Appuie sur Entrée pour continuer…"
  read -r
}

# ── Logs ──────────────────────────────────────────────────

show_logs() {
  _header
  _status_bar
  printf "  ${C_BOLD}${C_WHITE}Logs${C_RESET}  ${C_DIM}${LOGS_DIR}${C_RESET}\n\n"

  if [[ ! -d "$LOGS_DIR" ]]; then
    _warn "Aucun log disponible."; sleep 1.2; return
  fi

  local files=()
  while IFS= read -r f; do
    files+=("$f")
  done < <(find "$LOGS_DIR" -name "*.log" | sort -r | head -20)

  if [[ ${#files[@]} -eq 0 ]]; then
    _warn "Aucun fichier de log trouvé."; sleep 1.2; return
  fi

  local i=1
  for f in "${files[@]}"; do
    printf "  ${C_GRAY}%2d${C_RESET}  ${C_DIM}%s${C_RESET}\n" "$i" "${f#$LOGS_DIR/}"
    ((i++))
  done

  echo
  _prompt "Numéro à afficher (Entrée pour ignorer) :"
  read -r choice

  if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#files[@]}" ]]; then
    local target="${files[$choice]}"
    echo
    _line "─" "$C_GRAY"
    sed "s/^\[/${C_DIM}\[/;s/\]/${C_RESET}\]/" "$target"
    _line "─" "$C_GRAY"
    echo
    _prompt "Appuie sur Entrée pour continuer…"
    read -r
  fi
}


# ── Paramètres projet ─────────────────────────────────────────

edit_settings() {
  _header
  _status_bar
  printf "  ${C_BOLD}${C_WHITE}Paramètres du projet${C_RESET}

"

  while true; do
    _header
    _status_bar
    printf "  ${C_BOLD}${C_WHITE}Paramètres du projet${C_RESET}

"

    printf "  ${C_DIM}Extensions de code reconnues :${C_RESET}
"
    printf "    ${C_CYAN}%s${C_RESET}

" "${CODE_EXTENSIONS[*]}"

    printf "  ${C_DIM}Dossiers exclus de la recherche :${C_RESET}
"
    printf "    ${C_YELLOW}%s${C_RESET}

" "${EXCLUDED_DIRS[*]}"

    _line "╌" "$C_GRAY"
    printf "  ${C_GRAY}e${C_RESET}  Éditer les extensions
"
    printf "  ${C_GRAY}x${C_RESET}  Éditer les dossiers exclus
"
    printf "  ${C_GRAY}r${C_RESET}  Réinitialiser les valeurs par défaut
"
    printf "  ${C_GRAY}q${C_RESET}  Retour
"
    echo
    _prompt "Action :"
    read -r action || break

    case "$action" in

      e|E)
        echo
        printf "  ${C_DIM}Extensions actuelles :${C_RESET}  ${C_CYAN}%s${C_RESET}

" "${CODE_EXTENSIONS[*]}"
        _info "Entre les extensions séparées par des espaces ${C_DIM}(sans point)${C_RESET}"
        _prompt "Nouvelles extensions :"
        read -r new_exts || continue
        if [[ -n "$new_exts" ]]; then
          eval "CODE_EXTENSIONS=($new_exts)"
          save_config
          _ok "Extensions mises à jour."
        else
          _info "Annulé — aucune modification."
        fi
        sleep 0.8
        ;;

      x|X)
        echo
        printf "  ${C_DIM}Dossiers exclus actuels :${C_RESET}  ${C_YELLOW}%s${C_RESET}

" "${EXCLUDED_DIRS[*]}"
        _info "Entre les dossiers séparés par des espaces"
        _prompt "Nouveaux dossiers exclus :"
        read -r new_dirs || continue
        if [[ -n "$new_dirs" ]]; then
          eval "EXCLUDED_DIRS=($new_dirs)"
          save_config
          _ok "Dossiers exclus mis à jour."
        else
          _info "Annulé — aucune modification."
        fi
        sleep 0.8
        ;;

      r|R)
        _prompt "Réinitialiser les valeurs par défaut ? (o/N) :"
        read -r confirm || continue
        if [[ "$confirm" =~ ^[oO]$ ]]; then
          _config_defaults
          save_config
          _ok "Valeurs par défaut restaurées."
        else
          _info "Annulé."
        fi
        sleep 0.8
        ;;

      q|Q) break ;;
      *) _error "Action invalide."; sleep 0.5 ;;
    esac
  done
}

# ── Gestionnaire de connexions ────────────────────────────

# Format .connections : nom|url|clé_chiffrée_base64
# La clé est chiffrée avec openssl AES-256-CBC + mot de passe maître

_conn_init() {
  [[ -f "$CONNECTIONS_FILE" ]] || touch "$CONNECTIONS_FILE"
  chmod 600 "$CONNECTIONS_FILE"
}

_get_master_pass() {
  if [[ -z "$_MASTER_PASS" ]]; then
    echo
    _info "Mot de passe maître requis pour chiffrer/déchiffrer les clés API."
    _info "${C_DIM}(non stocké sur disque, valable pour cette session uniquement)${C_RESET}"
    printf "  ${C_MAGENTA}❯${C_RESET}  ${C_WHITE}Mot de passe maître :${C_RESET} "
    read -rs _MASTER_PASS
    echo
    [[ -z "$_MASTER_PASS" ]] && _MASTER_PASS="__no_key__"
  fi
}

_conn_encrypt() {
  local plaintext="$1"
  [[ -z "$plaintext" ]] && echo "" && return
  _get_master_pass
  echo "$plaintext" | openssl enc -aes-256-cbc -a -pbkdf2 -pass pass:"$_MASTER_PASS" 2>/dev/null | tr -d '\n'
}

_conn_decrypt() {
  local encrypted="$1"
  [[ -z "$encrypted" ]] && echo "" && return
  _get_master_pass
  echo "$encrypted" | openssl enc -d -aes-256-cbc -a -pbkdf2 -pass pass:"$_MASTER_PASS" 2>/dev/null
}

_conn_list() {
  [[ -f "$CONNECTIONS_FILE" ]] || return
  grep -v '^#' "$CONNECTIONS_FILE" | grep -v '^$' | cut -d'|' -f1
}

_conn_get() {
  local name="$1" field="$2"
  local line
  line=$(grep "^${name}|" "$CONNECTIONS_FILE" 2>/dev/null | head -1)
  [[ -z "$line" ]] && echo "" && return
  case "$field" in
    url)  echo "$line" | cut -d'|' -f2 ;;
    key)  echo "$line" | cut -d'|' -f3 ;;
  esac
}

_conn_set() {
  local name="$1" url="$2" encrypted_key="$3"
  _conn_init
  local tmpfile; tmpfile=$(mktemp)
  grep -v "^${name}|" "$CONNECTIONS_FILE" > "$tmpfile" 2>/dev/null || true
  echo "${name}|${url}|${encrypted_key}" >> "$tmpfile"
  mv "$tmpfile" "$CONNECTIONS_FILE"
  chmod 600 "$CONNECTIONS_FILE"
}

_conn_delete() {
  local name="$1"
  local tmpfile; tmpfile=$(mktemp)
  grep -v "^${name}|" "$CONNECTIONS_FILE" > "$tmpfile" 2>/dev/null || true
  mv "$tmpfile" "$CONNECTIONS_FILE"
}

_conn_test() {
  local url="$1" api_key="$2"
  local auth_header=()
  [[ -n "$api_key" ]] && auth_header=(-H "Authorization: Bearer ${api_key}")
  if curl -sf --max-time 5 "${auth_header[@]}" "${url}/v1/models" > /dev/null 2>&1; then
    return 0
  fi
  # Fallback : essai /health ou /api/tags (Ollama distant)
  curl -sf --max-time 5 "${url}/api/tags" > /dev/null 2>&1
}

_conn_load_active() {
  # Résout EXTERNAL_URL et EXTERNAL_API_KEY depuis ACTIVE_CONNECTION
  [[ -z "$ACTIVE_CONNECTION" ]] && return 1
  EXTERNAL_URL=$(_conn_get "$ACTIVE_CONNECTION" url)
  local enc_key; enc_key=$(_conn_get "$ACTIVE_CONNECTION" key)
  if [[ -n "$enc_key" ]]; then
    EXTERNAL_API_KEY=$(_conn_decrypt "$enc_key")
  else
    EXTERNAL_API_KEY=""
  fi
  [[ -n "$EXTERNAL_URL" ]]
}

manage_connections() {
  _conn_init
  local action choice names=() n i

  while true; do
    _header
    _status_bar
    printf "  ${C_BOLD}${C_WHITE}Gestionnaire de connexions${C_RESET}\n\n"

    # Mode actif
    if [[ "$CONNECTION_MODE" == "external" ]]; then
      printf "  ${C_DIM}Mode actif :${C_RESET}  ${C_BLUE}${C_BOLD}🌐 Serveur externe${C_RESET}"
      [[ -n "$ACTIVE_CONNECTION" ]] && printf "  ${C_DIM}(${ACTIVE_CONNECTION})${C_RESET}"
      echo
    else
      printf "  ${C_DIM}Mode actif :${C_RESET}  ${C_GREEN}${C_BOLD}● Ollama local${C_RESET}\n"
    fi
    echo

    # Liste des profils
    names=()
    while IFS= read -r n; do
      [[ -n "$n" ]] && names+=("$n")
    done < <(_conn_list)

    if [[ ${#names[@]} -eq 0 ]]; then
      printf "  ${C_GRAY}${C_DIM}Aucun profil externe configuré${C_RESET}\n\n"
    else
      printf "  ${C_DIM}Profils configurés :${C_RESET}\n\n"
      i=1
      for n in "${names[@]}"; do
        local marker="  "
        [[ "$n" == "$ACTIVE_CONNECTION" && "$CONNECTION_MODE" == "external" ]] && marker="${C_BLUE}✔${C_RESET} "
        local conn_url; conn_url=$(_conn_get "$n" url)
        local has_key; has_key=$(_conn_get "$n" key)
        local key_badge="${C_GRAY}no key${C_RESET}"
        [[ -n "$has_key" ]] && key_badge="${C_GREEN}🔑 chiffrée${C_RESET}"
        printf "  ${C_GRAY}%2d${C_RESET}  %b${C_WHITE}%s${C_RESET}  ${C_DIM}%s${C_RESET}  %b\n" \
          "$i" "$marker" "$n" "$conn_url" "$key_badge"
        ((i++))
      done
      echo
    fi

    _line "╌" "$C_GRAY"
    printf "  ${C_GRAY}o${C_RESET}  Basculer en ${C_GREEN}Ollama local${C_RESET}\n"
    printf "  ${C_GRAY}x${C_RESET}  Basculer sur un profil externe\n"
    printf "  ${C_GRAY}a${C_RESET}  Ajouter un profil de connexion\n"
    printf "  ${C_GRAY}e${C_RESET}  Éditer un profil\n"
    printf "  ${C_GRAY}t${C_RESET}  Tester la connexion active\n"
    printf "  ${C_GRAY}d${C_RESET}  Supprimer un profil\n"
    printf "  ${C_GRAY}p${C_RESET}  Changer le mot de passe maître ${C_DIM}(session)${C_RESET}\n"
    printf "  ${C_GRAY}q${C_RESET}  Retour\n"
    echo
    _prompt "Action :"
    read -r action || break

    case "$action" in

      o|O)
        CONNECTION_MODE="ollama"
        ACTIVE_CONNECTION=""
        EXTERNAL_URL=""
        EXTERNAL_API_KEY=""
        save_config
        _ok "Mode basculé sur ${C_GREEN}Ollama local${C_RESET}."
        sleep 1
        ;;

      x|X)
        if [[ ${#names[@]} -eq 0 ]]; then
          _warn "Aucun profil disponible. Ajoute-en un avec ${C_GRAY}a${C_RESET} d'abord."
          sleep 1.2; continue
        fi
        echo
        _prompt "Numéro du profil à activer :"
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#names[@]}" ]]; then
          ACTIVE_CONNECTION="${names[$choice]}"
          CONNECTION_MODE="external"
          if _conn_load_active; then
            save_config
            _ok "Connexion active : ${C_BLUE}${ACTIVE_CONNECTION}${C_RESET}  (${EXTERNAL_URL})"
          else
            _error "Impossible de charger le profil."
          fi
        else
          _error "Choix invalide."
        fi
        sleep 1
        ;;

      a|A)
        echo
        _prompt "Nom du profil (ex: serveur-perso, openrouter) :"
        read -r new_name
        [[ -z "$new_name" ]] && continue
        _prompt "URL du serveur (ex: http://192.168.1.10:1234) :"
        read -r new_url
        [[ -z "$new_url" ]] && continue
        _prompt "Clé API (laisser vide si pas d'auth) :"
        read -rs new_key
        echo
        local enc_key=""
        if [[ -n "$new_key" ]]; then
          enc_key=$(_conn_encrypt "$new_key")
          if [[ -z "$enc_key" ]]; then
            _error "Échec du chiffrement. Vérifie qu'openssl est installé."
            sleep 1.5; continue
          fi
        fi
        _conn_set "$new_name" "$new_url" "$enc_key"
        _ok "Profil ${C_BLUE}${new_name}${C_RESET} enregistré."
        sleep 1
        ;;

      e|E)
        if [[ ${#names[@]} -eq 0 ]]; then
          _warn "Aucun profil à éditer."; sleep 1; continue
        fi
        echo
        _prompt "Numéro du profil à éditer :"
        read -r choice
        if ! [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#names[@]}" ]]; then
          _error "Choix invalide."; sleep 0.8; continue
        fi
        local edit_name="${names[$choice]}"
        local cur_url; cur_url=$(_conn_get "$edit_name" url)
        echo
        _info "URL actuelle : ${C_DIM}${cur_url}${C_RESET}"
        _prompt "Nouvelle URL (Entrée pour garder) :"
        read -r upd_url
        [[ -z "$upd_url" ]] && upd_url="$cur_url"
        _info "Clé API chiffrée : ${C_DIM}(saisir pour changer, Entrée pour garder)${C_RESET}"
        printf "  ${C_MAGENTA}❯${C_RESET}  ${C_WHITE}Nouvelle clé API :${C_RESET} "
        read -rs upd_key
        echo
        local upd_enc=""
        if [[ -n "$upd_key" ]]; then
          upd_enc=$(_conn_encrypt "$upd_key")
        else
          upd_enc=$(_conn_get "$edit_name" key)
        fi
        _conn_set "$edit_name" "$upd_url" "$upd_enc"
        # Si ce profil est actif, recharger les credentials
        if [[ "$ACTIVE_CONNECTION" == "$edit_name" && "$CONNECTION_MODE" == "external" ]]; then
          _conn_load_active
        fi
        _ok "Profil ${C_BLUE}${edit_name}${C_RESET} mis à jour."
        sleep 1
        ;;

      t|T)
        if [[ "$CONNECTION_MODE" != "external" || -z "$ACTIVE_CONNECTION" ]]; then
          _warn "Aucune connexion externe active."; sleep 1; continue
        fi
        if [[ -z "$EXTERNAL_URL" ]]; then _conn_load_active; fi
        echo
        _info "Test de ${C_BLUE}${EXTERNAL_URL}${C_RESET}…"
        if _conn_test "$EXTERNAL_URL" "$EXTERNAL_API_KEY"; then
          _ok "Connexion OK — le serveur répond."
        else
          _error "Serveur inaccessible ou clé API invalide."
        fi
        sleep 1.5
        ;;

      d|D)
        if [[ ${#names[@]} -eq 0 ]]; then
          _warn "Aucun profil à supprimer."; sleep 1; continue
        fi
        echo
        _prompt "Numéro du profil à supprimer :"
        read -r choice
        if ! [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#names[@]}" ]]; then
          _error "Choix invalide."; sleep 0.8; continue
        fi
        local del_name="${names[$choice]}"
        _prompt "Confirmer la suppression de ${C_RED}${del_name}${C_RESET} ? (o/N) :"
        read -r confirm
        if [[ "$confirm" =~ ^[oO]$ ]]; then
          _conn_delete "$del_name"
          if [[ "$ACTIVE_CONNECTION" == "$del_name" ]]; then
            CONNECTION_MODE="ollama"
            ACTIVE_CONNECTION=""
            EXTERNAL_URL=""
            EXTERNAL_API_KEY=""
            save_config
            _warn "Profil actif supprimé — retour en mode Ollama local."
          else
            _ok "Profil ${del_name} supprimé."
          fi
        else
          _info "Annulé."
        fi
        sleep 1
        ;;

      p|P)
        echo
        _info "Le nouveau mot de passe maître s'applique à cette session uniquement."
        _warn "Les clés déjà chiffrées avec l'ancien mot de passe restent inchangées."
        printf "  ${C_MAGENTA}❯${C_RESET}  ${C_WHITE}Nouveau mot de passe maître :${C_RESET} "
        read -rs _MASTER_PASS
        echo
        [[ -z "$_MASTER_PASS" ]] && _MASTER_PASS="__no_key__"
        _ok "Mot de passe maître mis à jour pour cette session."
        sleep 1
        ;;

      q|Q) break ;;
      *) _error "Action invalide."; sleep 0.5 ;;
    esac
  done
}

# ── Menu principal ────────────────────────────────────────

main_menu() {
  load_session_state
  load_config
  # Restaure la connexion externe active si configurée
  if [[ "$CONNECTION_MODE" == "external" && -n "$ACTIVE_CONNECTION" ]]; then
    _conn_load_active 2>/dev/null || true
  fi
  PROJECT_DIR="$PWD"
  local choice menu_label

  while true; do
    _header
    _status_bar

    # Rappel du rôle du modèle actif
    if [[ -n "$SELECTED_MODEL" ]]; then
      menu_label=$(_profile_get "$SELECTED_MODEL" label)
      if [[ -n "$menu_label" ]]; then
        printf "  ${C_DIM}Rôle actif :${C_RESET}  ${C_WHITE}%s${C_RESET}\n" "$menu_label"
      fi
    fi

    if [[ -n "$SELECTED_MODEL" && -n "$SELECTED_AGENT" ]]; then
      printf "  ${C_DIM}Dernière session restaurée — prêt à démarrer.${C_RESET}\n\n"
    else
      printf "  ${C_DIM}Configure un modèle et un agent pour commencer.${C_RESET}\n\n"
    fi

    printf "  ${C_GRAY}1${C_RESET}  ${C_GREEN}${C_BOLD}Lancer session interactive${C_RESET}\n"
    printf "  ${C_GRAY}2${C_RESET}  Mode one-shot\n"
    printf "  ${C_GRAY}3${C_RESET}  Gérer les modèles ${C_DIM}(profils · usages · agents associés)${C_RESET}\n"
    printf "  ${C_GRAY}4${C_RESET}  Choisir un agent\n"
    printf "  ${C_GRAY}5${C_RESET}  Éditer un agent ${C_DIM}(créer · modifier les prompts)${C_RESET}\n"
    printf "  ${C_GRAY}6${C_RESET}  Voir les logs\n"
    printf "  ${C_GRAY}7${C_RESET}  Paramètres ${C_DIM}(extensions · dossiers exclus)${C_RESET}\n"
    printf "  ${C_GRAY}c${C_RESET}  Connexions ${C_DIM}(ollama local · serveur externe · profils chiffrés)${C_RESET}\n"
    printf "  ${C_GRAY}8${C_RESET}  ${C_RED}Quitter${C_RESET}\n"

    echo
    _prompt "Choix :"
    read -r choice || break

    case "$choice" in
      1) interactive_session ;;
      2) one_shot_mode ;;
      3) manage_models ;;
      4) select_agent ;;
      5) edit_agent ;;
      6) show_logs ;;
      7) edit_settings ;;
      c|C) manage_connections ;;
      8)
        clear
        printf "\n  ${C_DIM}À bientôt.${C_RESET}\n\n"
        sleep 0.4
        break
        ;;
      *) _error "Choix invalide."; sleep 0.5 ;;
    esac
  done
}

main_menu
exit 0
