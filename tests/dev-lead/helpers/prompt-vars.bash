# Bats helper: verify template variable coverage

assert_prompt_vars_covered() {
  local template="$1"
  # Extract variables referenced in template (${VAR} style)
  local used_vars
  used_vars=$(grep -oP '\$\{[A-Z_]+\}' "$template" | sort -u | sed 's/[${}]//g')
  # Extract variables declared in <!-- VARIABLES: --> comment
  local declared_vars
  declared_vars=$(grep -oP '(?<=<!-- VARIABLES: )[^>]+(?= -->)' "$template" | tr ',' '\n' | tr -d ' ' | sort -u)

  while IFS= read -r var; do
    [[ -z "$var" ]] && continue
    if ! echo "$declared_vars" | grep -qx "$var"; then
      echo "Variable \${$var} used in $template but not declared in <!-- VARIABLES: --> comment"
      return 1
    fi
  done <<< "$used_vars"
}
