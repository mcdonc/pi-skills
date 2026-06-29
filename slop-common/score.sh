# shellcheck shell=bash
# slop-common/score.sh — the 0–100 slop score (higher = more likely legitimate).
# Sourced by the policy skills. Pure function: stdin JSON -> stdout JSON.
#
# Slop score combines four cheap, reproducible signals (per #1042 §5):
#   trust      0-30  author allowlisted / account age / prior engagement
#   substance  0-30  body length, code blocks, repro keywords
#   grounding  0-25  cited file paths checked against the real repo tree
#   template   0-15  drive-by / AI-boilerplate phrase penalty (starts at 15)
# Weights are deliberately isolated here so outcomes (keep-closed vs promoted)
# can retune them over time.
#
# INPUT (stdin) JSON:
#   { "login","account_age_days","prior_contributions","is_allowlisted",
#     "body","kind":"issue|pr","cited_paths":[...],"repo_root":"/path or null" }
# OUTPUT (stdout) JSON:
#   { "score":N,"max_score":100,"checked_grounding":bool,
#     "components":{"trust","substance","grounding","template"},
#     "reasons":[...] }

# ---- grounding (shell, needs git + a checkout) ----
# slop_grounding <repo_root> <newline-separated cited paths>
slop_grounding() {
  local repo_root="$1" cited="${2:-}" tree total=0 real=0 missing hallucinated
  hallucinated=$'\n'

  # No paths cited -> neutral (don't reward or punish).
  if [ -z "$cited" ]; then
    jq -n '{score:8,max:25,checked:false,reasons:["no code paths cited"]}'
    return 0
  fi
  # No usable checkout -> can't verify, neutral + say so.
  if [ -z "$repo_root" ] || [ ! -d "$repo_root/.git" ]; then
    jq -n '{score:8,max:25,checked:false,reasons:["grounding not checked (no repo checkout)"]}'
    return 0
  fi
  tree=$(git -C "$repo_root" ls-tree -r --name-only HEAD 2>/dev/null) || tree=""
  if [ -z "$tree" ]; then
    jq -n '{score:8,max:25,checked:false,reasons:["grounding not checked (empty/unreadable tree)"]}'
    return 0
  fi

  while IFS= read -r p; do
    [ -z "$p" ] && continue
    total=$((total + 1))
    if grep -Fxq -- "$p" <<<"$tree"; then
      real=$((real + 1))
    else
      hallucinated="${hallucinated}${p}"$'\n'
    fi
  done <<<"$cited"

  missing=$((total - real))
  # fraction-real scaled to 25, minus a flat hallucination penalty.
  local frac score
  if [ "$total" -gt 0 ]; then frac=$((real * 25 / total)); else frac=8; fi
  score=$frac; [ "$missing" -gt 0 ] && score=$((score - 3))
  [ "$score" -lt 0 ] && score=0
  [ "$score" -gt 25 ] && score=25

  jq -n \
    --argjson real "$real" --argjson total "$total" --argjson missing "$missing" \
    --argjson score "$score" \
    --arg halluc "$hallucinated" \
    '{score:$score, max:25, checked:true,
      reasons: ([ "cited \(($total)) path(s): \(($real)) verified, \(($missing)) not found" ]
                + ($halluc | split("\n") | map(select(length>0)) | .[0:3]
                   | map("cites missing path: \(.)"))) }'
}

# ---- the score (pure, once grounding is known) ----
# stdin: INPUT JSON (above). stdout: OUTPUT JSON (above).
slop_score() {
  local input repo_root cited_paths grounding merged
  input=$(cat)
  repo_root=$(jq -r '.repo_root // empty' <<<"$input")
  cited_paths=$(jq -r '.cited_paths[]?' <<<"$input")
  grounding=$(slop_grounding "$repo_root" "$cited_paths")
  merged=$(jq -n --argjson in "$input" --argjson g "$grounding" '$in + {grounding:$g}' 2>/dev/null) || {
    echo "slop_score: failed to merge grounding into input" >&2; return 1; }

  # Template phrases that signal drive-by / AI-boilerplate submissions.
  # Lowercase substring match; each hit subtracts from the 15-point baseline.
  jq '
    def clamp(lo; hi; x): if x < lo then lo elif x > hi then hi else x end;
    (.body // "") as $body
    | ($body | length) as $len
    | (($body | ascii_downcase)) as $lc
    | ( if ($lc | test("\\x60\\x60\\x60")) then 1 else 0 end ) as $has_code  # ``` fence
    | ( if ($lc | test("steps to reproduce|expected behaviour|expected behavior|^expected:|actual:|reproduc|traceback|stack trace|error:|segfault|panic:|backtrace")) then 1 else 0 end ) as $repro

    # TRUST 0-30
    | (.is_allowlisted == true) as $allowed
    | (.account_age_days // 0) as $age
    | (.prior_contributions // 0) as $prior
    | ( if $allowed then 30
        else clamp(0; 30;
          ( if $age >= 365 then 20 elif $age >= 90 then 12 else 4 end )
          + (if $prior > 0 then 10 else 0 end) )
        end ) as $trust
    | ( if $allowed then [ "allowlisted contributor" ]
        else ( [ (if $age < 90 then "account <90d old" elif $age < 365 then "account <1yr old" else empty end),
                (if $prior == 0 then "no prior contributions in repo" else "has prior contributions in repo" end) ]
             | if length == 0 then [] else . end )
        end ) as $trust_r

    # SUBSTANCE 0-30
    | ( if $len < 50 then 2 elif $len < 200 then 10 elif $len < 600 then 18 else 24 end ) as $sub
    | clamp(0; 30; $sub + (if $has_code == 1 then 3 else 0 end) + (if $repro == 1 then 3 else 0 end)) as $substance
    | ( [ (if $len < 50 then "very short body (\($len) chars)" elif $len < 200 then "brief body (\($len) chars)" else empty end),
          (if $has_code == 1 then "includes a code block" else "no code block" end),
          (if $repro == 1 then "mentions repro steps/error detail" else "no repro detail" end) ]
       ) as $sub_r

    # TEMPLATE 0-15 (start at 15, subtract per boilerplate hit)
    | ( [ "i would be more than happy to", "i'\''d be more than happy to", "hope this helps",
          "let me know if you need", "as an ai", "i noticed that your", "happy to help",
          "stumbled upon your", "came across your (project|repo)", "great (project|repo)",
          "i love this (project|repo)", "feel free to reach out", "i have implemented a (fix|solution|feature)",
          "this (pr|pull request) (addresses|fixes|resolves|introduces)" ]
      | map(select(. as $p | $lc | test($p))) ) as $hits
    | clamp(0; 15; 15 - ($hits | length) * 4) as $template
    | ( if ($hits | length) == 0 then [ "no boilerplate phrases" ]
        else ($hits | map("boilerplate phrase: \u201c\(.)\u201d")) end ) as $template_r

    # GROUNDING (precomputed in shell)
    | .grounding as $g

    | ($trust + $substance + ($g.score) + $template) as $score
    | { score: $score,
        max_score: 100,
        checked_grounding: ($g.checked),
        components: { trust: $trust, substance: $substance, grounding: ($g.score), template: $template },
        reasons: ($trust_r + $sub_r + ($g.reasons) + $template_r) }
  ' <<<"$merged"
}
