#!/usr/bin/env bash
# Drive bin/fm-remote-inherit.sh as the remote receiver, crashing it (SIGKILL) at a chosen mv call.
ROOT=$1; T=$(mktemp -d); H=$T/home; mkdir -p $H/data $H/config
sha(){ sha256sum "$1"|awk '{print $1}'; }
put(){ # file gen [crash-on-mv-n]
  local f=$1 g=$2 n=${3:-0} PATHX=$PATH
  if [ "$n" -gt 0 ]; then mkdir -p $T/bin; rm -f $T/c
    cat > $T/bin/mv <<S
#!/usr/bin/env bash
c=\$(cat $T/c 2>/dev/null||echo 0); c=\$((c+1)); echo \$c > $T/c
[ \$c -eq $n ] && { kill -9 \$PPID; exit 1; }
exec /usr/bin/mv "\$@"
S
    chmod +x $T/bin/mv; PATHX=$T/bin:$PATH; fi
  echo "\$ fm-remote-inherit.sh put data/captain-shared.md <gen $g: $(cat $f)> ${n:+(crash at mv #$n)}"
  PATH=$PATHX FM_HOME=$H $ROOT/bin/fm-remote-inherit.sh put data/captain-shared.md $(wc -c <$f) $(sha $f) $g < $f 2>&1; echo "  exit=$?"
}
show(){ echo "  DEST: $(cat $H/data/captain-shared.md)"; echo "  receipt: $(tr '\n' ' ' < $H/data/.fm-inherit-captain-shared.md.generation)"; echo "  quarantines: $(ls $H/data | grep -c quarantine)"; }
for v in 1 2 3; do echo "inherited v$v" > $T/v$v; done
echo "== Scenario A: crash before publish, retry =="; put $T/v1 1; show; put $T/v2 2 2; show; put $T/v2 2; show
rm -rf $H; mkdir -p $H/data $H/config
echo "== Scenario B: crash after publish (before promote), retry =="; put $T/v1 1; put $T/v2 2 3; show; put $T/v2 2; show
rm -rf $H; mkdir -p $H/data $H/config
echo "== Scenario C: double interruption gen2 after publish, gen3 before publish, retry gen3 =="; put $T/v1 1; put $T/v2 2 3; show; put $T/v3 3 2; show; put $T/v3 3; show
rm -rf $H; mkdir -p $H/data $H/config
echo "== Scenario D: crash before publish, captain edits DEST, retry (must quarantine) =="; put $T/v1 1; put $T/v2 2 2; chmod u+w $H/data/captain-shared.md; echo "captain edit" > $H/data/captain-shared.md; put $T/v2 2; show; echo "  quarantine content: $(cat $H/data/*quarantine*)"
rm -rf $H; mkdir -p $H/data $H/config
echo "== Scenario E: malformed receipts fail closed =="; put $T/v1 1 >/dev/null
R=$H/data/.fm-inherit-captain-shared.md.generation; chmod u+w $R
printf 'applied\n1\n14\n%s\nput' $(sha $T/v1) > $R; echo "-- no trailing newline"; put $T/v2 2
{ printf 'pending\n1\n14\n%s\nput\n' $(sha $T/v1); printf 'applied\n1\n14\n%s\nput\n' $(sha $T/v1); } > $R; echo "-- 10-line receipt led by pending"; put $T/v2 2
printf '1\n14\n%s\nput\n' $(sha $T/v1) > $R; echo "-- legacy 4-line receipt"; put $T/v2 2; show
rm -rf $T
