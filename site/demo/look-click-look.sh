# An agent's look-click-look loop: eyes finds the 7 on Calculator, vhid clicks it and
# types the rest, and eyes looks again for the answer. The same steps are the eyes and
# vhid MCP tools of the same names (docs/mcp.md). Filmed by scripts/film-demo.

stage() {
    open -a Calculator
    stage_alone Calculator
    vhid press escape
    vhid move 800 250
}

film() {
    say 'where is the 7?'
    run 'eyes find 7 --exact'
    point=${out##*$'\n'}
    point=${point%%$'\t'*}
    run "vhid click ${point/,/ }"
    run "vhid type '*6='"
    say 'did it work?'
    run 'eyes find 42 --exact'
}
