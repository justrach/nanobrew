#!/usr/bin/env python3
"""Disposable GitHub-hosted runners only. Never reset a developer machine."""
import json, os, pathlib, platform, shutil, statistics, subprocess, time
if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted":
    raise SystemExit("This benchmark requires a disposable GitHub-hosted runner")
out = pathlib.Path("benchmark-results"); out.mkdir(exist_ok=True)
nb = os.environ["NB_BENCH_BINARY"]
base = dict(os.environ)
rows = []
count = 0

def run(args, env=base, check=True):
    global count
    count += 1
    start = time.perf_counter()
    try:
        p = subprocess.run(args, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=360)
        elapsed = time.perf_counter() - start
        output, code = p.stdout, p.returncode
    except subprocess.TimeoutExpired as e:
        output, code, elapsed = str(e.stdout), 124, time.perf_counter()-start
    (out/f"{count:03d}.log").write_text("$ " + " ".join(args) + "\n" + output)
    if check and code:
        raise RuntimeError(f"{args} failed ({code}): {output[-2000:]}")
    return elapsed, output, code

info = {"date":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()), "arch":platform.machine(),
        "os":run(["sw_vers"])[1], "cpu":run(["sysctl","-n","machdep.cpu.brand_string"])[1].strip(),
        "homebrew":run(["brew","--version"])[1].strip(), "nanobrew":run([nb,"--version"])[1].strip(),
        "iterations":3,"rows":rows,
        "method":"Alternating manager order. Cold package downloads: target absent, fresh Homebrew download cache and fresh Nanobrew root. Homebrew uninstall primes API metadata before timing; Nanobrew init is also outside timing. Warm: remove target after cold install, retain cache/store, install again. Existing Homebrew dependencies retained. Initialization and Homebrew auto-update excluded. Network and OS filesystem caches uncontrolled. Different upstream/bottle routes allowed. Only successful installs with functional smoke checks count. This is a package-manager end-to-end comparison, not extraction-only."}
assert info["homebrew"].startswith("Homebrew 7.0.2"), info["homebrew"]
assert "0.1.212" in info["nanobrew"], info["nanobrew"]
fixtures=out.resolve()/"fixture"; fixtures.mkdir(exist_ok=True)
(fixtures/"hello.txt").write_text("nanobrew benchmark fixture\n")
(fixtures/"justfile").write_text("hello:\n    @echo nanobrew-benchmark-ok\n")
brew_prefix=run(["brew","--prefix"])[1].strip()

def smoke(manager, token):
    binary=("/opt/nanobrew/prefix/bin/" if manager=="nanobrew" else brew_prefix+"/bin/")+token
    version=run([binary,"--version"])[1].strip()
    if token=="tree": args=[binary,str(fixtures)]; expected="hello.txt"
    elif token=="fd": args=[binary,"hello",str(fixtures)]; expected="hello.txt"
    else: args=[binary,"--justfile",str(fixtures/"justfile"),"hello"]; expected="nanobrew-benchmark-ok"
    output=run(args)[1]
    if expected not in output: raise RuntimeError(f"smoke failed: {output}")
    return version

def save():
    (out/"results.json").write_text(json.dumps(info,indent=2)+"\n")

for token in ["tree","fd","just"]:
    for iteration in range(3):
        for manager in (["nanobrew","homebrew"] if iteration%2==0 else ["homebrew","nanobrew"]):
            entry={"package":token,"iteration":iteration+1,"manager":manager}
            rows.append(entry)
            print(f"Starting {token} {iteration+1} {manager}",flush=True)
            try:
                env=dict(base)
                if manager=="nanobrew":
                    run(["sudo","rm","-rf","/opt/nanobrew"])
                    run(["sudo","mkdir","-p","/opt/nanobrew"])
                    run(["sudo","chown",os.environ["USER"],"/opt/nanobrew"])
                    run([nb,"init"])
                    install=[nb,"install",token]; remove=[nb,"remove",token]
                else:
                    cache=pathlib.Path(os.environ["RUNNER_TEMP"])/f"brew-bench-{token}-{iteration}"
                    cache.mkdir()
                    env["HOMEBREW_CACHE"]=str(cache)
                    run(["brew","uninstall","--force","--ignore-dependencies",token],env,False)
                    install=["brew","install",token]; remove=["brew","uninstall","--force","--ignore-dependencies",token]
                for scenario in ["cold","warm"]:
                    elapsed, output, code=run(install,env,False)
                    if code: raise RuntimeError(f"{scenario} install failed ({code}): {output[-1500:]}")
                    version=smoke(manager,token)
                    entry[scenario]={"seconds":elapsed,"version":version,"smoke":"passed"}
                    run(remove,env)
                entry["status"]="passed"
            except Exception as e:
                entry["status"]="failed"; entry["error"]=str(e)
                print(str(e),flush=True)
            save()
summary=["# Homebrew 7.0.2 vs Nanobrew 0.1.212", "",info["os"],info["arch"],"",info["method"],"", "| Package | Scenario | nb median (s) | brew median (s) | brew / nb |", "|---|---|---:|---:|---:|"]
for token in ["tree","fd","just"]:
    for scenario in ["cold","warm"]:
        sets={m:[r[scenario]["seconds"] for r in rows if r["package"]==token and r["manager"]==m and r.get("status")=="passed"] for m in ["nanobrew","homebrew"]}
        if all(len(v)==3 for v in sets.values()):
            n,b=[statistics.median(sets[m]) for m in ["nanobrew","homebrew"]]
            summary.append(f"| {token} | {scenario} | {n:.3f} | {b:.3f} | {b/n:.2f}x |")
        else: summary.append(f"| {token} | {scenario} | incomplete | incomplete | excluded |")
summary += ["", "See results.json for every sample, installed versions, failures and metadata. Check version equivalence before making speed claims."]
report="\n".join(summary)+"\n"
(out/"summary.md").write_text(report)
with open(os.environ["GITHUB_STEP_SUMMARY"],"a") as f:f.write(report)
print(report)
if any(r.get("status")!="passed" for r in rows): raise SystemExit(1)
