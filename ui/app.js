// LAN Speed's tabs on the chassis window: Run a test, History, Schedule, How to test, and its parts of Overview, Site address, Updates and Storage.
(function (P) {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var SRC = { run: "Run here", schedule: "Scheduled", server: "iperf3 from the device", browser: "Browser" };
  var EVERY = { off: "no scheduled tests", "15m": "every 15 minutes", "30m": "every 30 minutes", "1h": "every hour", "3h": "every 3 hours", "6h": "every 6 hours", "12h": "twice a day", "24h": "once a day" };
  function app(st) { return (st && st.app) || {}; }
  function hist(st) { return app(st).history || {}; }
  function devices(st) { return hist(st).devices || []; }
  function touched(id) { ["input", "change"].forEach(function (e) { $(id).addEventListener(e, function () { $(id).dataset.touched = "1"; }); }); }
  function quiet(id, v) { var e = $(id); if (e.dataset.touched) return; if (e.type === "checkbox") e.checked = !!v; else e.value = v == null ? "" : v; }
  function untouch(ids) { ids.forEach(function (id) { $(id).dataset.touched = ""; }); }
  function mbit(v) { return v == null ? "–" : (v >= 100 ? Math.round(v) : v.toFixed(1)) + " Mbit/s"; }
  function num(v) { return v == null ? "" : String(v); }
  function plural(n, one, many) { return n + " " + (n === 1 ? one : many); }
  // A history row: [id, at, source, addr, host, proto, dir, to, from, ping, jitter, loss, retrans, ok, error, client, secs, streams]
  function R(a) { return { id: a[0], at: a[1], src: a[2], addr: a[3], host: a[4], proto: a[5], dir: a[6], to: a[7], from: a[8], ping: a[9], jitter: a[10], loss: a[11], retrans: a[12], ok: a[13] === 1, error: a[14], client: a[15], secs: a[16], streams: a[17] }; }
  function rows(st) { return (hist(st).rows || []).map(R); }
  function deviceOf(r, devs) {
    for (var i = 0; i < devs.length; i++) { var d = devs[i]; if ((r.host && d.host === r.host) || (r.addr && (d.host === r.addr || d.addr === r.addr))) return d; }
    return null;
  }
  function keyOf(r, devs) { var d = deviceOf(r, devs); return d ? "d:" + d.host : "a:" + (r.addr || r.host); }
  function nameOf(r, devs) { var d = deviceOf(r, devs); return d ? d.name : (r.addr || r.host || "?"); }
  function how(r) {
    var p = r.proto === "http" ? "" : " · " + r.proto.toUpperCase() + (r.streams > 1 ? " × " + r.streams : "");
    return SRC[r.src] + (r.src === "browser" ? (r.client ? " · " + r.client : "") : p);
  }
  function details(r) {
    if (!r.ok) return r.error || "failed";
    var d = [];
    if (r.ping != null) d.push("ping " + r.ping + " ms"); if (r.jitter != null) d.push("jitter " + r.jitter + " ms");
    if (r.loss != null) d.push(r.loss + "% lost"); if (r.retrans != null) d.push(plural(r.retrans, "retransmit", "retransmits"));
    if (r.secs && r.src !== "browser") d.push(r.secs + " s");
    return d.join(", ");
  }
  function fillDevices(sel, devs, keepFirst) {
    var sig = JSON.stringify(devs); if (sel.dataset.sig === sig) return; sel.dataset.sig = sig; var v = sel.value;
    while (sel.options.length > keepFirst) sel.remove(keepFirst);
    devs.forEach(function (d) { var o = document.createElement("option"); o.value = d.host; o.textContent = d.name + " — " + d.host; sel.appendChild(o); });
    sel.value = v; if (sel.value !== v) sel.value = "";
  }
  function goto(name) { P.showTab(name); try { history.replaceState(null, "", "#" + name); } catch (e) { /* fine */ } }
  document.querySelectorAll("[data-goto]").forEach(function (a) { a.addEventListener("click", function (e) { e.preventDefault(); goto(a.dataset.goto); }); });

  // ---------------------------------------------------------------- Run a test
  var RUN = ["rt-host", "rt-port", "rt-proto", "rt-dir", "rt-secs", "rt-streams", "rt-rate"];
  function runCmd() {
    var h = $("rt-host").value.trim() || "address", c = "iperf3 -c " + h;
    if ($("rt-port").value && $("rt-port").value !== "5201") c += " -p " + $("rt-port").value;
    c += " -t " + ($("rt-secs").value || 10); if (+$("rt-streams").value > 1) c += " -P " + $("rt-streams").value;
    if ($("rt-proto").value === "udp") c += " -u -b " + ($("rt-rate").value || 100) + "M";
    if ($("rt-dir").value === "down") c += " -R";
    $("rt-cmd").textContent = "Runs: " + c + ($("rt-dir").value === "both" ? ", then the same with -R" : "");
    $("rt-rate-f").hidden = $("rt-proto").value !== "udp";
  }
  RUN.forEach(function (id) { $(id).addEventListener("input", runCmd); $(id).addEventListener("change", runCmd); });
  $("rt-dev").addEventListener("change", function () {
    var d = devices(P.S && P.S.status).filter(function (x) { return x.host === $("rt-dev").value; })[0];
    if (d) { $("rt-host").value = d.host; $("rt-port").value = d.port || 5201; } runCmd();
  });
  $("rt-host").addEventListener("input", function () { $("rt-dev").value = ""; });
  function legTiles(box, legs) {
    P.clear(box);
    legs.forEach(function (l) {
      var dir = l.to != null || (!l.ok && l.dir === "to") ? "Synology → device" : "device → Synology";
      if (!l.ok) { P.tile(box, "failed", dir); return; }
      P.tile(box, mbit(l.to != null ? l.to : l.from), dir + (l.proto === "udp" ? ", UDP" : ""));
      if (l.retrans != null) P.tile(box, String(l.retrans), "retransmits (" + dir + ")");
      if (l.jitter != null) P.tile(box, l.jitter + " ms", "jitter (" + dir + ")");
      if (l.loss != null) P.tile(box, l.loss + "%", "packets lost (" + dir + ")");
    });
  }
  P.register("run", {
    render: function (st) {
      var a = app(st), devs = devices(st), last = a.lastrun, run = a.running, all = rows(st);
      fillDevices($("rt-dev"), devs, 1);
      if (last && !$("rt-host").value && !$("rt-host").dataset.filled) {   // the last test, ready to run again
        $("rt-host").dataset.filled = "1"; $("rt-host").value = last.host; $("rt-port").value = last.port || 5201; $("rt-proto").value = last.proto || "tcp";
        $("rt-dir").value = last.dir || "up"; $("rt-secs").value = last.secs || 10; $("rt-streams").value = last.streams || 1; $("rt-rate").value = last.rate || 100;
        $("rt-dev").value = devs.some(function (d) { return d.host === last.host; }) ? last.host : "";
      }
      runCmd();
      $("rt-go").disabled = P.busy || P.role !== "admin" || !(a.server || {}).up;
      // A test in progress.
      $("rt-running").hidden = !run;
      if (run) { var span = Math.max(1, run.until - run.from), done = Math.min(1, (P.S.now - run.from) / span);
        $("rt-bar").style.width = Math.round(done * 100) + "%"; $("rt-running-text").textContent = "Testing " + run.host + " — about " + Math.max(0, run.until - P.S.now) + " s to go."; }
      // The last test run from here.
      var show = last && last.source === "run";
      $("rt-result-card").hidden = !show;
      if (show) {
        $("rt-when").textContent = (last.name ? last.name + " (" + last.host + ")" : last.host) + " · " + P.ago(last.at);
        var sig = JSON.stringify(last); if ($("rt-result").dataset.sig !== sig) { $("rt-result").dataset.sig = sig; legTiles($("rt-result"), last.legs || []); }
        var n = $("rt-result-note"); n.className = "small" + (last.error ? "" : " muted");
        n.textContent = last.error ? last.error : last.proto.toUpperCase() + ", " + last.secs + " s each way, " + plural(last.streams, "stream", "parallel streams") + (last.proto === "udp" ? ", sending at " + last.rate + " Mbit/s" : "") + ". Speeds are what the receiving side measured.";
      }
      // Saved devices, with each one's latest result.
      var tb = $("rt-devices"), sig2 = JSON.stringify(devs) + "|" + (all[0] || {}).id + "|" + P.busy + "|" + P.role; if (tb.dataset.sig === sig2) return; tb.dataset.sig = sig2; P.clear(tb);
      if (!devs.length) { var r0 = P.el("tr"), c0 = P.cell("No devices named yet: test one above and press Save as a device, or name one from History.", "empty"); c0.colSpan = 5; r0.appendChild(c0); tb.appendChild(r0); }
      devs.forEach(function (d) {
        var latest = all.filter(function (r) { var x = deviceOf(r, [d]); return x && r.ok; })[0];
        var lt = P.el("div"); if (latest) { lt.appendChild(P.el("span", [latest.to != null ? "↓ " + mbit(latest.to) : "", latest.from != null ? "↑ " + mbit(latest.from) : ""].filter(Boolean).join("  "), "ls-num")); lt.appendChild(P.el("span", SRC[latest.src] + " · " + P.ago(latest.at), "sub")); } else lt.textContent = "–";
        var acts = P.el("span", null, "row");
        acts.appendChild(P.btn("Test", "", function () { $("rt-dev").value = d.host; $("rt-host").value = d.host; $("rt-port").value = d.port || 5201; runCmd(); $("rt-host").scrollIntoView({ block: "center" }); }));
        acts.appendChild(P.btn("Rename", "", function () { var n = window.prompt("A new name for " + d.host + ":", d.name); if (n && n.trim()) P.act("device", { host: d.host, name: n.trim(), port: d.port || 5201 }); }));
        acts.appendChild(P.btn("Remove", "danger", function () { P.act("undevice", { host: d.host }, "Forget the name " + d.name + "? Its results stay in History under its address."); }));
        var who = P.el("div"); who.appendChild(P.el("b", d.name)); if (d.addr && d.addr !== d.host) who.appendChild(P.el("span", d.addr, "sub"));
        P.row(tb, [P.cell(who), d.host, P.cell(String(d.port || 5201), "n"), P.cell(lt), P.cell(acts, "n")]);
      });
    }
  });
  $("rt-go").onclick = function () {
    P.act("runtest", { host: $("rt-host").value.trim(), port: $("rt-port").value, proto: $("rt-proto").value, dir: $("rt-dir").value, secs: $("rt-secs").value, streams: $("rt-streams").value, rate: $("rt-rate").value });
  };
  $("rt-save").onclick = function () {
    var h = $("rt-host").value.trim(); if (!h) { P.showErr("Type the device's address first."); return; }
    var n = window.prompt("A name for " + h + " (for instance Office PC):", ""); if (n && n.trim()) P.act("device", { host: h, name: n.trim(), port: $("rt-port").value || 5201 });
  };
  runCmd();

  // ---------------------------------------------------------------- History
  ["hi-dev", "hi-kind", "hi-range"].forEach(function (id) { $(id).addEventListener("change", function () { $("hi-rows").dataset.sig = ""; if (P.S) P.showTab("history"); }); });
  function filtered(st) {
    var devs = devices(st), dev = $("hi-dev").value, kind = $("hi-kind").value, days = +$("hi-range").value, since = days ? P.S.now - days * 86400 : 0;
    return rows(st).filter(function (r) { return (!dev || keyOf(r, devs) === dev) && (!kind || r.src === kind) && r.at >= since; });
  }
  function fillDeviceFilter(st) {
    var devs = devices(st), seen = {}, opts = [];
    devs.forEach(function (d) { seen["d:" + d.host] = 1; opts.push(["d:" + d.host, d.name]); });
    rows(st).forEach(function (r) { var k = keyOf(r, devs); if (!seen[k]) { seen[k] = 1; opts.push([k, (r.addr || r.host) + (r.src === "browser" && r.client ? " (" + r.client + ")" : "")]); } });
    var sel = $("hi-dev"), sig = JSON.stringify(opts); if (sel.dataset.sig === sig) return; sel.dataset.sig = sig; var v = sel.value;
    while (sel.options.length > 1) sel.remove(1);
    opts.forEach(function (o) { var e = document.createElement("option"); e.value = o[0]; e.textContent = o[1]; sel.appendChild(e); });
    sel.value = v; if (sel.value !== v) sel.value = "";
  }
  function median(a) { if (!a.length) return null; var s = a.slice().sort(function (x, y) { return x - y; }), m = Math.floor(s.length / 2); return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; }
  function niceMax(v) { if (!(v > 0)) return 100; var p = Math.pow(10, Math.floor(Math.log10(v))), f = v / p; return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10) * p; }
  function svgEl(tag, attrs) { var e = document.createElementNS("http://www.w3.org/2000/svg", tag); Object.keys(attrs || {}).forEach(function (k) { e.setAttribute(k, attrs[k]); }); return e; }
  function chart(box, list, days, joined) {
    P.clear(box);
    var pts = list.filter(function (r) { return r.ok && (r.to != null || r.from != null); }).sort(function (a, b) { return a.at - b.at; });
    if (!pts.length) { box.appendChild(P.el("div", "No results to draw for this choice yet.", "empty")); return; }
    var W = Math.max(320, box.clientWidth || 640), H = 220, L = 44, Rm = 12, T = 22, B = 26;
    var now = P.S.now, x0 = days ? now - days * 86400 : pts[0].at, x1 = days ? now : Math.max(pts[pts.length - 1].at, x0 + 60);
    if (x1 - x0 < 60) x0 = x1 - 60;
    var ymax = niceMax(Math.max.apply(null, pts.map(function (r) { return Math.max(r.to || 0, r.from || 0); })) * 1.05);
    function X(t) { return L + (t - x0) / (x1 - x0) * (W - L - Rm); } function Y(v) { return T + (1 - v / ymax) * (H - T - B); }
    var svg = svgEl("svg", { viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": "Speed over time" }), g = svgEl("g", { "class": "grid" });
    [0, 0.25, 0.5, 0.75, 1].forEach(function (f) {
      var y = Y(ymax * f); g.appendChild(svgEl("line", { x1: L, x2: W - Rm, y1: y, y2: y }));
      var t = svgEl("text", { x: L - 8, y: y + 4, "text-anchor": "end" }); t.textContent = String(Math.round(ymax * f)); svg.appendChild(t);
    });
    var unit = svgEl("text", { x: 0, y: 10 }); unit.textContent = "Mbit/s"; svg.appendChild(unit);
    svg.appendChild(g);
    var fmt = (x1 - x0) > 2 * 86400 ? { day: "numeric", month: "short" } : { hour: "2-digit", minute: "2-digit" };
    [0, 0.5, 1].forEach(function (f) { var t = svgEl("text", { x: L + f * (W - L - Rm), y: H - 6, "text-anchor": f === 0 ? "start" : f === 1 ? "end" : "middle" }); t.textContent = new Date((x0 + f * (x1 - x0)) * 1000).toLocaleString(undefined, fmt); svg.appendChild(t); });
    [["to", "var(--ls-to)"], ["from", "var(--ls-from)"]].forEach(function (s) {
      var ps = pts.filter(function (r) { return r[s[0]] != null; }); if (!ps.length) return;
      if (joined && ps.length > 1) svg.appendChild(svgEl("polyline", { points: ps.map(function (r) { return X(r.at).toFixed(1) + "," + Y(r[s[0]]).toFixed(1); }).join(" "), fill: "none", stroke: s[1], "stroke-width": 2, "stroke-linejoin": "round", "stroke-linecap": "round" }));
      ps.forEach(function (r) { svg.appendChild(svgEl("circle", { cx: X(r.at).toFixed(1), cy: Y(r[s[0]]).toFixed(1), r: 4, fill: s[1], stroke: "#fff", "stroke-width": 2 })); });
    });
    var cross = svgEl("line", { y1: T, y2: H - B, stroke: "#98a4b0", "stroke-width": 1, visibility: "hidden" }); svg.appendChild(cross);
    box.appendChild(svg);
    var tip = P.el("div", null, "tip"); tip.hidden = true; box.appendChild(tip);
    var devs = devices(P.S.status);
    svg.addEventListener("mousemove", function (ev) {
      var rect = svg.getBoundingClientRect(), mx = (ev.clientX - rect.left) * W / rect.width, best = null, bd = 1e9;
      pts.forEach(function (r) { var d = Math.abs(X(r.at) - mx); if (d < bd) { bd = d; best = r; } });
      if (!best || bd > 40) { tip.hidden = true; cross.setAttribute("visibility", "hidden"); return; }
      cross.setAttribute("x1", X(best.at)); cross.setAttribute("x2", X(best.at)); cross.setAttribute("visibility", "visible");
      P.clear(tip); tip.appendChild(P.el("b", nameOf(best, devs))); tip.appendChild(P.el("span", " · " + P.when(best.at), "muted"));
      [["to", "Synology → device", "var(--ls-to)"], ["from", "Device → Synology", "var(--ls-from)"]].forEach(function (s) {
        if (best[s[0]] == null) return; var l = P.el("div"); var i = P.el("i"); i.style.background = s[2]; l.appendChild(i); l.appendChild(document.createTextNode(s[1] + ": " + mbit(best[s[0]]))); tip.appendChild(l); });
      tip.appendChild(P.el("div", how(best), "muted"));
      tip.hidden = false; var px = X(best.at) / W * rect.width; tip.style.left = Math.min(Math.max(0, px + 12), rect.width - tip.offsetWidth) + "px"; tip.style.top = "8px";
    });
    svg.addEventListener("mouseleave", function () { tip.hidden = true; cross.setAttribute("visibility", "hidden"); });
  }
  P.register("history", {
    render: function (st) {
      var h = hist(st), devs = devices(st);
      fillDeviceFilter(st);
      var list = filtered(st), days = +$("hi-range").value;
      var sig = JSON.stringify([h.total, (h.rows || [])[0], devs, $("hi-dev").value, $("hi-kind").value, days, P.busy, P.role]);
      if ($("hi-rows").dataset.sig === sig) return; $("hi-rows").dataset.sig = sig;
      $("hi-count").textContent = plural(list.length, "test", "tests");
      var ok = list.filter(function (r) { return r.ok; }), tos = ok.map(function (r) { return r.to; }).filter(function (v) { return v != null; }), froms = ok.map(function (r) { return r.from; }).filter(function (v) { return v != null; });
      var t = $("hi-tiles"); P.clear(t);
      P.tile(t, String(list.length), "tests"); P.tile(t, mbit(median(tos)), "Synology → device, median"); P.tile(t, mbit(median(froms)), "device → Synology, median");
      P.tile(t, String(list.length - ok.length), "failed");
      chart($("hi-chart"), list, days, !!$("hi-dev").value);   // one device: a line; several: points only (a line between devices means nothing)
      var tb = $("hi-rows"); P.clear(tb);
      if (!list.length) { var r0 = P.el("tr"), c0 = P.cell(h.total ? "No tests match this choice." : "No tests yet. Run one, open the browser test on a phone, or run iperf3 on a computer (How to test).", "empty"); c0.colSpan = 7; r0.appendChild(c0); tb.appendChild(r0); }
      list.slice(0, 200).forEach(function (r) {
        var d = deviceOf(r, devs), who = P.el("div"); who.appendChild(P.el("b", d ? d.name : (r.addr || r.host))); if (d) who.appendChild(P.el("span", r.addr || r.host, "sub"));
        var name = d ? P.el("span") : P.btn("Name it", "", function () { var n = window.prompt("A name for " + (r.addr || r.host) + " (for instance Living room AP):", ""); if (n && n.trim()) P.act("device", { host: r.addr || r.host, name: n.trim(), port: 5201 }); });
        var tr = P.row(tb, [P.ago(r.at), P.cell(who), how(r), P.cell(P.el("span", r.ok ? (r.to != null ? mbit(r.to) : "–") : "–", "ls-num"), "n"), P.cell(P.el("span", r.ok ? (r.from != null ? mbit(r.from) : "–") : "–", "ls-num"), "n"), P.cell(details(r), "small"), P.cell(name, "n")]);
        tr.title = P.when(r.at); if (!r.ok) tr.className = "ls-failed";
      });
      $("hi-foot").textContent = (list.length > 200 ? "The latest 200 of these are listed. " : "") + "The window holds the latest " + (h.rows || []).length + " of " + (h.total || 0) + " tests; Save all as CSV has every one" + (h.first ? ", back to " + new Date(h.first * 1000).toLocaleDateString() : "") + ".";
    },
    badge: function (st) { var s = (app(st).schedule || {}).state, b = $("badge-history"); b.hidden = !(s === "slow" || s === "failed"); b.textContent = "!"; b.title = s === "slow" ? "The last scheduled test was slow" : "The last scheduled test failed"; }
  });
  $("hi-csv").onclick = function (e) { e.preventDefault(); if (P.role !== "admin") { P.showErr("Only DSM administrators can save the history."); return; } window.location.href = P.withToken("api.cgi?action=historycsv"); };
  $("hi-clear").onclick = function () { P.act("clearhist", {}, "Remove every test from the history? Device names and the schedule stay. A backup has them, if you've made one."); };

  // ---------------------------------------------------------------- Schedule
  var SCH = ["sc-every", "sc-dev", "sc-host", "sc-port", "sc-proto", "sc-dir", "sc-secs", "sc-streams", "sc-rate", "sc-thr", "sc-keep", "sc-alert"];
  SCH.forEach(touched);
  $("sc-proto").addEventListener("change", function () { $("sc-rate-f").hidden = $("sc-proto").value !== "udp"; });
  $("sc-dev").addEventListener("change", function () { var d = devices(P.S && P.S.status).filter(function (x) { return x.host === $("sc-dev").value; })[0]; if (d) { $("sc-host").value = d.host; $("sc-port").value = d.port || 5201; $("sc-host").dataset.touched = "1"; } });
  $("sc-host").addEventListener("input", function () { $("sc-dev").value = ""; });
  P.register("schedule", {
    render: function (st) {
      var a = app(st), s = a.schedule || {}, devs = devices(st);
      fillDevices($("sc-dev"), devs, 1);
      quiet("sc-every", s.every || "off"); quiet("sc-host", s.host); quiet("sc-port", s.port || 5201); quiet("sc-proto", s.proto || "tcp"); quiet("sc-dir", s.dir || "both");
      quiet("sc-secs", s.secs || 10); quiet("sc-streams", s.streams || 1); quiet("sc-rate", s.rate || 100); quiet("sc-thr", s.threshold || ""); quiet("sc-keep", String(s.keep == null ? 365 : s.keep)); quiet("sc-alert", s.alert);
      if (!$("sc-dev").dataset.touched) $("sc-dev").value = devs.some(function (d) { return d.host === $("sc-host").value; }) ? $("sc-host").value : "";
      $("sc-rate-f").hidden = $("sc-proto").value !== "udp";
      var t = $("sc-tiles"); P.clear(t);
      var on = s.every && s.every !== "off", dn = devs.filter(function (d) { return d.host === s.host; })[0];
      P.tile(t, on ? EVERY[s.every] : "off", on ? "to " + (dn ? dn.name : s.host) : "scheduled tests");
      P.tile(t, on && s.next ? (s.next <= P.S.now + 30 ? "about now" : "in " + Math.max(1, Math.round((s.next - P.S.now) / 60)) + " min") : "–", "next test");
      P.tile(t, s.state === "slow" ? "slow" : s.state === "failed" ? "failed" : s.state === "ok" ? "fine" : "–", "last scheduled test" + (s.last ? ", " + P.ago(s.last) : ""));
      P.tile(t, s.threshold ? s.threshold + " Mbit/s" : "–", "slow is below");
      var tb = $("sc-recent"), list = rows(st).filter(function (r) { return r.src === "schedule"; }).slice(0, 12), sig = JSON.stringify(list.map(function (r) { return r.id; }));
      if (tb.dataset.sig === sig) return; tb.dataset.sig = sig; P.clear(tb);
      if (!list.length) { var r0 = P.el("tr"), c0 = P.cell("No scheduled tests yet.", "empty"); c0.colSpan = 4; r0.appendChild(c0); tb.appendChild(r0); }
      list.forEach(function (r) {
        var slow = s.threshold && r.ok && ((r.to != null && r.to < s.threshold) || (r.from != null && r.from < s.threshold));
        var d = P.el("div"); d.appendChild(document.createTextNode(details(r))); if (slow) { d.appendChild(document.createTextNode(" ")); d.appendChild(P.chip("below " + s.threshold, "warn")); }
        var tr = P.row(tb, [P.ago(r.at), P.cell(P.el("span", r.to != null ? mbit(r.to) : "–", "ls-num"), "n"), P.cell(P.el("span", r.from != null ? mbit(r.from) : "–", "ls-num"), "n"), P.cell(d, "small")]);
        if (!r.ok) tr.className = "ls-failed";
      });
    }
  });
  $("sc-save").onclick = function () {
    P.act("schedule", { every: $("sc-every").value, host: $("sc-host").value.trim(), port: $("sc-port").value, proto: $("sc-proto").value, dir: $("sc-dir").value, secs: $("sc-secs").value,
      streams: $("sc-streams").value, rate: $("sc-rate").value, threshold: $("sc-thr").value || 0, alert: $("sc-alert").checked ? 1 : 0, keep: $("sc-keep").value }).then(function () { untouch(SCH); });
  };

  // ---------------------------------------------------------------- How to test
  var OS = {
    win: { install: "Download iperf3 for Windows (the iperf.fr download page links current builds), unzip it, and open PowerShell in that folder.", cmd: ".\\iperf3.exe" },
    mac: { install: "Install it with Homebrew: brew install iperf3 — then use Terminal.", cmd: "iperf3" },
    linux: { install: "Install it with your package manager: sudo apt install iperf3 (Debian, Ubuntu) or sudo dnf install iperf3 (Fedora).", cmd: "iperf3" }
  };
  var os = /Mac/.test(navigator.platform) ? "mac" : /Linux/.test(navigator.platform) ? "linux" : "win";
  document.querySelectorAll("#ht-os button").forEach(function (b) { b.setAttribute("aria-selected", b.dataset.os === os ? "true" : "false"); b.addEventListener("click", function () { os = b.dataset.os; document.querySelectorAll("#ht-os button").forEach(function (o) { o.setAttribute("aria-selected", o === b ? "true" : "false"); }); $("ht-cmds").dataset.sig = ""; if (P.S) P.showTab("howto"); }); });
  P.register("howto", {
    render: function (st) {
      var a = app(st), ip = a.lan_ip || "this-synology", port = a.iperf_port || 5201, sv = a.server || {};
      if (a.qr && $("ht-qr").dataset.qr !== a.qr) { $("ht-qr").src = "data:image/png;base64," + a.qr; $("ht-qr").dataset.qr = a.qr; }
      $("ht-url").textContent = a.url || "…"; $("ht-open").href = a.url || "#";
      $("ht-port").textContent = String(port);
      $("ht-server").textContent = sv.error ? "— but it can't listen right now: " + sv.error : sv.up ? "and is waiting" : "— its container isn't running";
      var sig = [ip, port, os].join("|"), tb = $("ht-cmds"); if (tb.dataset.sig === sig) return; tb.dataset.sig = sig; P.clear(tb);
      $("ht-install").textContent = OS[os].install;
      var base = OS[os].cmd + " -c " + ip + (port !== 5201 ? " -p " + port : "");
      [["Upload: this computer → Synology", base], ["Download: Synology → this computer", base + " -R"], ["Both at the same time", base + " --bidir"],
       ["Fast links (2.5 GbE and up): 4 parallel streams", base + " -P 4"], ["UDP at 500 Mbit/s: jitter and packet loss", base + " -u -b 500M"]].forEach(function (c) {
        var code = P.el("code", c[1]), b = P.el("button", "Copy", "btn"); b.onclick = function () { P.copy(c[1], b, code); };
        var cell = P.el("div", null, "row"); cell.appendChild(code); cell.appendChild(b);
        P.row(tb, [P.cell(c[0], "k"), P.cell(cell)]);
      });
    }
  });
  $("ht-copy-url").onclick = function () { P.copy($("ht-url").textContent, $("ht-copy-url"), $("ht-url")); };

  // ---------------------------------------------------------------- Overview, Site address, Updates, Storage
  P.register("overview", { tiles: function (t, st) {
    var a = app(st), r = rows(st).filter(function (x) { return x.ok; })[0], sv = a.server || {};
    P.tile(t, r ? mbit(r.to != null ? r.to : r.from) : "–", r ? "latest test, " + P.ago(r.at) : "no tests yet");
    P.tile(t, String((hist(st).total) || 0), "tests in the history");
    P.tile(t, sv.error ? "can't listen" : sv.up ? "port " + (a.iperf_port || 5201) : "stopped", "iperf3 server" + (sv.version ? " " + sv.version : ""));
  } });
  $("set-iperf-port").addEventListener("input", function () { $("set-url").dataset.touched = "1"; });
  P.register("site", {
    fill: function (st) { $("set-iperf-port").value = app(st).iperf_port || 5201; },
    values: function () { return { iperf_port: $("set-iperf-port").value }; }
  });
  P.register("updates", {
    render: function (st) {
      var box = $("upd-app"), iu = st.image_update || {}, a = app(st), ls = iu.librespeed || {}, ip = iu.iperf3 || {}; P.clear(box);
      box.appendChild(P.el("p", "Installed: iperf3 " + ((a.server || {}).version || "?") + " (Alpine's package" + (ip.current ? " " + ip.current : "") + ", built on this Synology) and LibreSpeed " + ((a.web || {}).version || "?") + "."));
      if (iu.error) { box.appendChild(P.el("p", "Couldn't look for updates: " + iu.error + ".", "muted small")); return; }
      var news = [];
      if (ls.available) news.push("LibreSpeed " + ls.latest + " is out");
      if (ip.available) news.push("Alpine has iperf3 " + ip.latest);
      if (news.length) {
        box.appendChild(P.el("p", news.join("; ") + ". Updating backs up the history first, then " + (ls.available ? "moves LibreSpeed to the new release" : "") + (ls.available && ip.available ? " and " : "") + (ip.available ? "rebuilds the iperf3 image" : "") + "; tests stop for a minute.", "muted small"));
        if (ls.available && ls.page) { var l = P.el("a", "What's new in LibreSpeed"); l.href = ls.page; l.target = "_blank"; l.rel = "noopener"; box.appendChild(l); box.appendChild(P.el("span", " ")); }
        box.appendChild(P.btn("Update", "primary", function () { P.act("updateapp", {}, "Update now? A backup is made first; tests stop for a minute."); }));
      } else box.appendChild(P.el("p", (ls.note ? ls.note + ". " : "") + (ls.latest || ip.latest ? "Both are current" + (iu.checked ? " (checked " + P.ago(iu.checked) + ")" : "") + ". " : "")
        + "LibreSpeed stays at a tested release and moves on when you say so; iperf3 comes from Alpine Linux.", "muted small"));
    }
  });
  P.register("storage", { render: function (s, st, box) {
    P.clear(box); var c = P.el("div", null, "card"); c.appendChild(P.el("h2", "LAN Speed's data")); var tbl = P.el("table"), tb = P.el("tbody"); tbl.appendChild(tb); c.appendChild(tbl);
    P.kv(tb, "History (SQLite, in lanspeed_data)", P.mb(s.history || 0), true); P.kv(tb, "Browser test results (LibreSpeed's SQLite, in lanspeed_librespeed)", P.mb(s.librespeed || 0), true);
    P.kv(tb, "iperf3 reports waiting to be added", String(s.waiting || 0), true);
    box.appendChild(c);
  } });
})(window.Panel);
