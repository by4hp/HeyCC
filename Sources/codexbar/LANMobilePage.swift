import Foundation

// MARK: - 移动端彩色视图

/// 渲染整页移动端用量看板。server-rendered 首屏 + 前端 30s 轮询 `/api/snapshot.json`。
/// 数据用 `<script id="snapshot">` 内嵌一份 JSON，JS 启动后接管重绘。
func renderMobilePage(_ s: LANSnapshot, token: String) -> String {
    let snapshotJSON = String(data: renderSnapshotJSON(s), encoding: .utf8) ?? "{}"
    // </script> 不能出现在内嵌 JSON 里 —— 转义防 XSS。
    let safeJSON = snapshotJSON.replacingOccurrences(of: "</", with: "<\\/")
    let updated = s.lastUpdated.map { clockText($0) } ?? "尚未更新"

    return """
    <!DOCTYPE html>
    <html lang="zh-CN">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
    <meta name="theme-color" content="#0E1015" media="(prefers-color-scheme: dark)">
    <meta name="theme-color" content="#F5F7FA" media="(prefers-color-scheme: light)">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <title>HeyCC · Code Companion</title>
    <style>
    \(mobileCSS)
    </style>
    </head>
    <body>
    <div class="page">

      <header class="hero">
        <div class="hero-left">
          <button class="pet-wrap" id="pet-btn" aria-label="戳一下小精灵">
            <img class="pet" id="pet"
                 src="/pets/\(s.petVariant)/idle.png?t=\(token)"
                 alt="HeyCC">
            <span class="pet-glow" aria-hidden="true"></span>
          </button>
          <div class="hero-text">
            <div class="brand">HeyCC</div>
            <div class="sub">Code Companion</div>
          </div>
        </div>
        <div class="hero-right">
          <div class="clock" id="now">--:--</div>
          <button class="refresh" id="refresh" aria-label="刷新">↻</button>
        </div>
      </header>

      <div class="grid two">
        \(mobileProviderCard(s.claude, accent: .claude, days: daysUntilRenewal(day: s.claudeRenewalDay), renewalDay: s.claudeRenewalDay))
        \(mobileProviderCard(s.codex, accent: .codex, days: daysUntilRenewal(day: s.codexRenewalDay), renewalDay: s.codexRenewalDay))
      </div>

      \(mobileQuipCard(s.quip))

      <section class="card stat-card" id="workshop">
        <div class="card-head">
          <span class="card-title">今日工坊</span>
          <span class="card-meta" id="workshop-date">\(htmlEscape(dayMonthText(s.generatedAt)))</span>
        </div>
        <div class="stat-row">
          <div class="stat">
            <div class="stat-num" id="today-tokens">\(shortTokens(s.todayTokens))</div>
            <div class="stat-cap">tokens · 今日</div>
          </div>
          <div class="stat">
            <div class="stat-num" id="week-tokens">\(shortTokens(s.weekTokens))</div>
            <div class="stat-cap">tokens · 7 天</div>
          </div>
        </div>
      </section>

      <section class="card chart-card">
        <div class="card-head">
          <span class="card-title">Token 趋势</span>
          <div class="seg" id="range-seg" role="tablist">
            <button data-range="day" class="seg-btn active">日</button>
            <button data-range="week" class="seg-btn">周</button>
            <button data-range="month" class="seg-btn">月</button>
          </div>
        </div>
        <div class="chart-wrap">
          <svg id="chart" viewBox="0 0 700 220" preserveAspectRatio="none" width="100%" height="220"></svg>
        </div>
        <div class="chart-axis" id="chart-axis"></div>
        <div class="legend">
          <span class="dot" style="background:var(--claude)"></span>Claude
          <span class="dot" style="background:var(--codex);margin-left:14px"></span>Codex
          <span class="peak" id="chart-peak"></span>
        </div>
      </section>

      <footer>
        <span id="updated-text">上次刷新 \(updated)</span> · 每 30 秒自动同步
        <a class="switch" href="?view=kindle&t=\(token)">↗ Kindle 墨水屏版</a>
      </footer>
    </div>

    <script id="snapshot" type="application/json">\(safeJSON)</script>
    <script>
    (function(){
      const TOKEN = \(jsString(token));
      const POLL_MS = 30000;
      const COLORS = {
        claude: getComputedStyle(document.documentElement).getPropertyValue('--claude').trim() || '#DC8242',
        codex: getComputedStyle(document.documentElement).getPropertyValue('--codex').trim() || '#4DCBBE',
        gridLine: 'rgba(127,127,127,0.18)',
      };

      let currentRange = 'day';
      let snapshot = JSON.parse(document.getElementById('snapshot').textContent);

      // === 小精灵状态机 ===
      const PET_VARIANT = (snapshot.petVariant === 'flower') ? 'flower' : 'chibi';
      const PET_FRAMES = ['idle','blink','look_left','look_right','happy','thinking','worried','sleepy','celebrate'];
      const petImg = document.getElementById('pet');
      // 预加载所有帧（浏览器缓存命中 24h，第二次以后零延迟）
      PET_FRAMES.forEach(f => {
        const im = new Image();
        im.src = '/pets/' + PET_VARIANT + '/' + f + '.png?t=' + encodeURIComponent(TOKEN);
      });
      let petFrame = 'idle';
      let petBaseline = 'idle';  // 持续情绪：idle / thinking / worried / sleepy
      let petBusy = false;       // 正在播放一次性动画
      function setPetFrame(name) {
        petImg.src = '/pets/' + PET_VARIANT + '/' + name + '.png?t=' + encodeURIComponent(TOKEN);
        petFrame = name;
      }
      function petTransient(name, ms, then) {
        petBusy = true;
        setPetFrame(name);
        setTimeout(() => {
          setPetFrame(then || petBaseline);
          petBusy = false;
        }, ms);
      }
      function updatePetMood() {
        const fhMax = Math.max(
          (snapshot.claude || {}).fiveHourPercent || 0,
          (snapshot.codex || {}).fiveHourPercent || 0
        );
        const hour = new Date().getHours();
        let next;
        if (fhMax >= 90) next = 'worried';
        else if (fhMax >= 75) next = 'thinking';
        else if (hour >= 23 || hour < 6) next = 'sleepy';
        else next = 'idle';
        petBaseline = next;
        if (!petBusy) setPetFrame(petBaseline);
      }
      // 闲时眨眼（每 4.5s 一次 tick，概率 50%）
      setInterval(() => {
        if (petBusy || petFrame !== petBaseline) return;
        if (Math.random() < 0.5) petTransient('blink', 140);
      }, 4500);
      // 闲时左右看（每 9s tick，概率 35%）
      setInterval(() => {
        if (petBusy || petFrame !== petBaseline) return;
        if (Math.random() < 0.35) {
          const side = Math.random() > 0.5 ? 'look_left' : 'look_right';
          petTransient(side, 1600);
        }
      }, 9000);
      // 点一下小精灵：celebrate + 跳一下
      document.getElementById('pet-btn').addEventListener('click', () => {
        petTransient('celebrate', 900);
        petImg.classList.remove('jump');
        // reflow 让动画能重放
        void petImg.offsetWidth;
        petImg.classList.add('jump');
      });

      function shortTokens(n) {
        if (!n || n < 0) return '0';
        if (n >= 1e6) return (n / 1e6).toFixed(1) + 'M';
        if (n >= 1e3) return (n / 1e3).toFixed(1) + 'k';
        return String(n);
      }

      function tick() {
        const now = new Date();
        const hh = String(now.getHours()).padStart(2, '0');
        const mm = String(now.getMinutes()).padStart(2, '0');
        document.getElementById('now').textContent = hh + ':' + mm;
      }

      function renderStat() {
        document.getElementById('today-tokens').textContent = shortTokens(snapshot.todayTokens);
        document.getElementById('week-tokens').textContent = shortTokens(snapshot.weekTokens);
      }

      function capitalize(s) {
        return s ? s.charAt(0).toUpperCase() + s.slice(1) : s;
      }

      function formatDays(n) {
        if (n == null || n < 0) return '—';
        if (n === 0) return '今天';
        return n + ' 天';
      }

      function renderProviders() {
        const r = snapshot.renewal || {};
        ['claude','codex'].forEach(key => {
          const p = snapshot[key] || {};
          const fh = p.fiveHourPercent;
          const wk = p.weeklyPercent;
          const ring = document.querySelector('[data-ring="'+key+'"]');
          if (ring && fh != null) {
            const pct = Math.max(0, Math.min(100, fh));
            const C = 2 * Math.PI * 44;
            ring.querySelector('.ring-arc').style.strokeDasharray = (C * pct / 100) + ' ' + C;
            ring.querySelector('.ring-num').textContent = Math.round(pct) + '%';
          }
          const wkBar = document.querySelector('[data-week="'+key+'"]');
          if (wkBar && wk != null) {
            const pct = Math.max(0, Math.min(100, wk));
            wkBar.querySelector('.bar-fill').style.width = pct + '%';
            wkBar.querySelector('.bar-pct').textContent = Math.round(pct) + '%';
          }
          const planEl = document.querySelector('[data-plan="'+key+'"]');
          if (planEl) planEl.textContent = p.plan ? capitalize(p.plan) : '识别中';
          // provider 卡里的续费行（已合并自原独立卡片）
          const renewalEl = document.getElementById(key + '-renewal');
          if (renewalEl) {
            const days = key === 'claude' ? r.claudeDaysLeft : r.codexDaysLeft;
            const day = key === 'claude' ? r.claudeDay : r.codexDay;
            renewalEl.textContent = formatDays(days) + ' · ' + day + ' 号';
          }
        });
      }

      function renderChart() {
        const svg = document.getElementById('chart');
        const w = 700, h = 220, padTop = 16, padBot = 22, padX = 12;
        const innerW = w - padX * 2;
        const innerH = h - padTop - padBot;

        let claude = [], codex = [], labels = [];
        if (currentRange === 'day') {
          // 24h 滚动数据：[0]=23h 前、[23]=当前小时。
          const fullClaude = snapshot.hourlyClaude || new Array(24).fill(0);
          const fullCodex = snapshot.hourlyCodex || new Array(24).fill(0);
          const fullTotals = fullClaude.map((c, i) => c + (fullCodex[i] || 0));
          // 找首/末非零索引 —— 把睡觉的整段空时段裁掉，但中间真实空白保留。
          let first = -1, last = -1;
          for (let i = 0; i < 24; i++) if (fullTotals[i] > 0) { first = i; break; }
          for (let i = 23; i >= 0; i--) if (fullTotals[i] > 0) { last = i; break; }
          if (first < 0) {
            // 完全没数据：兜底回完整 24h，免得空图
            first = 0; last = 23;
          } else {
            // 前后各 1 小时 padding，让首末柱不贴边
            first = Math.max(0, first - 1);
            last = Math.min(23, last + 1);
            // 最少 8 列，避免活跃时段只 3-4 小时时图表挤窄
            const minLen = 8;
            if (last - first + 1 < minLen) {
              first = Math.max(0, last - minLen + 1);
            }
          }
          claude = fullClaude.slice(first, last + 1);
          codex = fullCodex.slice(first, last + 1);
          // 反推每列对应的真实"时"号
          const nowH = new Date().getHours();
          const sliceLen = claude.length;
          for (let i = 0; i < sliceLen; i++) {
            const idx = first + i;
            const off = -(23 - idx);
            const hour = (nowH + off + 48) % 24;
            // 首末必标，中间每 4 小时标一次
            const showLabel = (i === 0) || (i === sliceLen - 1) || (hour % 4 === 0);
            labels.push(showLabel ? String(hour).padStart(2,'0') : '');
          }
        } else if (currentRange === 'week') {
          const slice = (snapshot.daily || []).slice(-7);
          claude = slice.map(p => p.claude);
          codex = slice.map(p => p.codex);
          labels = slice.map(p => weekdayLabel(p.dayStart));
        } else {
          const slice = (snapshot.daily || []).slice(-30);
          claude = slice.map(p => p.claude);
          codex = slice.map(p => p.codex);
          labels = slice.map((p, i, arr) => {
            if (i === 0 || i === arr.length - 1 || i % 5 === 0) {
              const d = new Date(p.dayStart);
              return d.getDate();
            }
            return '';
          });
        }

        const totals = claude.map((c, i) => c + (codex[i] || 0));
        const peak = Math.max(1, ...totals);

        let svgInner = '';
        // 网格线
        for (let g = 0; g <= 4; g++) {
          const y = padTop + innerH * (1 - g / 4);
          svgInner += '<line x1="'+padX+'" y1="'+y+'" x2="'+(w-padX)+'" y2="'+y+'" stroke="'+COLORS.gridLine+'" stroke-width="1"/>';
        }

        const n = totals.length;
        if (n > 0) {
          const slotW = innerW / n;
          const barW = Math.max(2, Math.min(slotW * 0.62, 22));
          for (let i = 0; i < n; i++) {
            const cx = padX + slotW * i + slotW / 2;
            const cHeight = (claude[i] / peak) * innerH;
            const dHeight = ((codex[i] || 0) / peak) * innerH;
            const totalH = cHeight + dHeight;
            const yBase = padTop + innerH;
            // Codex 在底，Claude 在上 —— 但视觉上 stack 谁在上无所谓；用 Claude 在底更直觉
            const yClaude = yBase - cHeight;
            const yCodex = yClaude - dHeight;
            if (cHeight > 0.5) {
              svgInner += '<rect x="'+(cx-barW/2)+'" y="'+yClaude+'" width="'+barW+'" height="'+cHeight+'" rx="2" fill="'+COLORS.claude+'"/>';
            }
            if (dHeight > 0.5) {
              svgInner += '<rect x="'+(cx-barW/2)+'" y="'+yCodex+'" width="'+barW+'" height="'+dHeight+'" rx="2" fill="'+COLORS.codex+'"/>';
            }
            if (totalH < 0.5) {
              // 空柱画一个细的占位线
              svgInner += '<line x1="'+(cx-barW/2)+'" y1="'+yBase+'" x2="'+(cx+barW/2)+'" y2="'+yBase+'" stroke="'+COLORS.gridLine+'" stroke-width="1.5"/>';
            }
          }
        }

        svg.innerHTML = svgInner;

        // x 轴
        const axis = document.getElementById('chart-axis');
        axis.innerHTML = labels.map(l => '<span>'+escapeHTML(l)+'</span>').join('');

        // 峰值标签
        document.getElementById('chart-peak').textContent = '峰值 ' + shortTokens(peak);
      }

      function weekdayLabel(iso) {
        const d = new Date(iso);
        return ['日','一','二','三','四','五','六'][d.getDay()];
      }

      function escapeHTML(s) {
        return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'})[c]);
      }

      function renderQuip() {
        const el = document.getElementById('quip-text');
        if (el && snapshot.quip) el.textContent = snapshot.quip;
      }

      function renderUpdated() {
        const el = document.getElementById('updated-text');
        if (!el) return;
        const ts = snapshot.lastUpdatedAt;
        if (!ts) { el.textContent = '尚未刷新'; return; }
        const d = new Date(ts);
        const hh = String(d.getHours()).padStart(2,'0');
        const mm = String(d.getMinutes()).padStart(2,'0');
        const ss = String(d.getSeconds()).padStart(2,'0');
        el.textContent = '上次刷新 ' + hh + ':' + mm + ':' + ss;
      }

      function renderAll() {
        renderStat();
        renderProviders();
        renderChart();
        renderQuip();
        renderUpdated();
      }

      function fetchSnapshot() {
        fetch('/api/snapshot.json?t=' + encodeURIComponent(TOKEN), { cache: 'no-store' })
          .then(r => r.ok ? r.json() : null)
          .then(data => {
            if (!data) return;
            snapshot = data;
            renderAll();
            petTransient('happy', 700, null);
            // happy 播完后会自动落到新的 baseline；这里也刷一下心情
            setTimeout(updatePetMood, 750);
          })
          .catch(() => {});
      }

      // 切换日/周/月
      document.getElementById('range-seg').addEventListener('click', (e) => {
        const btn = e.target.closest('.seg-btn');
        if (!btn) return;
        document.querySelectorAll('#range-seg .seg-btn').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        currentRange = btn.dataset.range;
        renderChart();
      });

      // 手动刷新
      document.getElementById('refresh').addEventListener('click', () => {
        const btn = document.getElementById('refresh');
        btn.classList.add('spinning');
        fetchSnapshot();
        setTimeout(() => btn.classList.remove('spinning'), 600);
      });

      tick();
      setInterval(tick, 1000);
      setInterval(fetchSnapshot, POLL_MS);
      // 心情每分钟也根据时间重判一次（半夜会切到 sleepy）
      setInterval(updatePetMood, 60_000);
      // 首屏服务端已渲染，但 SVG 图表需要 JS 重画一次
      renderAll();
      updatePetMood();
    })();
    </script>
    </body>
    </html>
    """
}

// MARK: - 卡片片段

private enum MobileAccent { case claude, codex }

private func mobileProviderCard(_ p: LANSnapshot.Provider,
                                accent: MobileAccent,
                                days: Int,
                                renewalDay: Int) -> String {
    let key = accent == .claude ? "claude" : "codex"
    let accentVar = accent == .claude ? "var(--claude)" : "var(--codex)"
    let softVar = accent == .claude ? "var(--claude-soft)" : "var(--codex-soft)"
    let plan = (p.plan?.isEmpty == false) ? p.plan!.capitalized : "识别中"
    let fhValue = p.fiveHourPercent.map { min(max($0, 0), 100) } ?? 0
    let wkValue = p.weeklyPercent.map { min(max($0, 0), 100) } ?? 0
    let circumference = 2.0 * Double.pi * 44.0
    let dashOffset = circumference * fhValue / 100.0
    let fhDisplay = p.fiveHourPercent.map { "\(Int($0.rounded()))%" } ?? "—"
    let wkDisplay = p.weeklyPercent.map { "\(Int($0.rounded()))%" } ?? "—"
    let fhResetText = p.fiveHourResetAt.map { relativeText($0) } ?? "—"

    var errBlock = ""
    if let err = p.error, !err.isEmpty {
        errBlock = """
        <div class="prov-err">⚠ \(htmlEscape(err))</div>
        """
    }

    return """
    <section class="card prov-card" style="--accent: \(accentVar); --accent-soft: \(softVar);">
      <div class="prov-top">
        <div class="prov-name">\(htmlEscape(p.name))</div>
        <div class="prov-plan" data-plan="\(key)">\(htmlEscape(plan))</div>
      </div>
      <div class="prov-body">
        <div class="ring-wrap" data-ring="\(key)">
          <svg class="ring" viewBox="0 0 100 100" width="92" height="92">
            <circle class="ring-bg" cx="50" cy="50" r="44" fill="none" stroke-width="8"/>
            <circle class="ring-arc" cx="50" cy="50" r="44" fill="none" stroke-width="8"
                    stroke-linecap="round"
                    stroke-dasharray="\(dashOffset) \(circumference)"
                    transform="rotate(-90 50 50)"/>
          </svg>
          <div class="ring-num">\(fhDisplay)</div>
          <div class="ring-cap">5h</div>
        </div>
        <div class="prov-meta">
          <div class="prov-line">
            <span class="prov-line-cap">5h 重置</span>
            <span class="prov-line-val">\(htmlEscape(fhResetText))</span>
          </div>
          <div class="prov-line week-row" data-week="\(key)">
            <span class="prov-line-cap">7 天</span>
            <span class="bar"><i class="bar-fill" style="width:\(Int(wkValue))%"></i></span>
            <span class="prov-line-val bar-pct">\(wkDisplay)</span>
          </div>
          <div class="prov-line">
            <span class="prov-line-cap">续费</span>
            <span class="prov-line-val" id="\(key)-renewal">\(formatRenewalDays(days)) · \(renewalDay) 号</span>
          </div>
        </div>
      </div>
      \(errBlock)
    </section>
    """
}

private func mobileQuipCard(_ quip: String?) -> String {
    let text = (quip?.isEmpty == false) ? quip! : "—"
    return """
    <section class="card quip-card">
      <span class="quip-pet">✨</span>
      <span class="quip-text" id="quip-text">\(htmlEscape(text))</span>
    </section>
    """
}

func formatRenewalDays(_ days: Int) -> String {
    if days < 0 { return "—" }
    if days == 0 { return "今天" }
    return "\(days) 天"
}

/// 把 Swift 字符串变成 JS 字符串字面量（含引号），仅用于内嵌 token。
private func jsString(_ text: String) -> String {
    var out = "\""
    for ch in text {
        switch ch {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default: out.append(ch)
        }
    }
    out += "\""
    return out
}

// MARK: - CSS

private let mobileCSS: String = """
:root {
  color-scheme: light dark;
  --bg: #F5F7FA;
  --card: #FFFFFF;
  --text: #1A1A1F;
  --text-dim: #6E6E76;
  --text-faint: #A3A3AC;
  --divider: rgba(0,0,0,0.06);
  --shadow: 0 2px 12px rgba(20,20,30,0.06);
  --claude: #DC8242;
  --claude-soft: rgba(220,130,66,0.13);
  --codex: #2FB9AB;
  --codex-soft: rgba(47,185,171,0.13);
  --accent: var(--claude);
  --accent-soft: var(--claude-soft);
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0E1015;
    --card: #1B1D24;
    --text: #F0F0F4;
    --text-dim: #9A9AA3;
    --text-faint: #66666E;
    --divider: rgba(255,255,255,0.06);
    --shadow: 0 2px 12px rgba(0,0,0,0.4);
    --claude: #FF9E5C;
    --claude-soft: rgba(255,158,92,0.16);
    --codex: #5DDBCC;
    --codex-soft: rgba(93,219,204,0.16);
  }
}
* { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
html, body {
  margin: 0; padding: 0;
  background: var(--bg);
  color: var(--text);
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro", "PingFang SC", "Segoe UI", system-ui, sans-serif;
  -webkit-font-smoothing: antialiased;
  font-feature-settings: "tnum";
}
.page {
  max-width: 760px;
  margin: 0 auto;
  padding: 16px 16px env(safe-area-inset-bottom);
  display: flex; flex-direction: column; gap: 14px;
}
.hero {
  display: flex; justify-content: space-between; align-items: center;
  padding: 8px 4px 4px;
}
.hero-left {
  display: flex; align-items: center; gap: 12px;
}
.pet-wrap {
  position: relative;
  width: 64px; height: 64px;
  border: none; background: transparent;
  padding: 0; cursor: pointer;
  -webkit-tap-highlight-color: transparent;
  flex-shrink: 0;
}
.pet-wrap .pet {
  width: 100%; height: 100%; display: block;
  image-rendering: pixelated;
  image-rendering: -webkit-optimize-contrast;
  /* 让小精灵稍微浮在装饰光晕之上 */
  position: relative; z-index: 2;
  transition: transform 0.2s ease;
}
.pet-wrap:active .pet { transform: scale(0.94); }
.pet-glow {
  position: absolute; inset: 6px;
  border-radius: 50%;
  background: radial-gradient(closest-side,
    var(--claude-soft), transparent 70%);
  z-index: 1;
  pointer-events: none;
}
@keyframes pet-jump {
  0% { transform: translateY(0) rotate(0); }
  25% { transform: translateY(-9px) rotate(-3deg); }
  50% { transform: translateY(-3px) rotate(2deg); }
  75% { transform: translateY(-6px) rotate(-1deg); }
  100% { transform: translateY(0) rotate(0); }
}
.pet.jump { animation: pet-jump 0.9s ease-out; }
.hero-text { display: flex; flex-direction: column; gap: 3px; }
.hero .brand {
  font-size: 22px; font-weight: 700; letter-spacing: 0.5px;
  line-height: 1;
}
.hero .sub {
  font-size: 12px; color: var(--text-faint); letter-spacing: 1.5px;
}
.hero-right { display: flex; align-items: center; gap: 12px; }
.clock {
  font-variant-numeric: tabular-nums;
  font-size: 17px; font-weight: 600; color: var(--text-dim);
}
.refresh {
  width: 36px; height: 36px; border-radius: 18px;
  border: none; background: var(--card); color: var(--text);
  font-size: 18px; font-weight: 600;
  box-shadow: var(--shadow);
  cursor: pointer;
  transition: transform 0.2s ease;
}
.refresh.spinning { transform: rotate(360deg); }

.card {
  background: var(--card);
  border-radius: 18px;
  padding: 16px;
  box-shadow: var(--shadow);
}
.card-head {
  display: flex; justify-content: space-between; align-items: center;
  margin-bottom: 10px;
}
.card-title {
  font-size: 13px; font-weight: 600; color: var(--text-dim);
  letter-spacing: 1.5px; text-transform: uppercase;
}
.card-meta {
  font-size: 12px; color: var(--text-faint);
}

.grid.two {
  display: grid;
  grid-template-columns: 1fr;
  gap: 14px;
}
@media (min-width: 560px) {
  .grid.two { grid-template-columns: 1fr 1fr; }
}

/* Provider card */
.prov-card { padding: 18px 18px 16px; }
.prov-top {
  display: flex; justify-content: space-between; align-items: baseline;
  margin-bottom: 14px;
}
.prov-name {
  font-size: 16px; font-weight: 700; color: var(--accent);
  letter-spacing: 0.4px;
}
.prov-plan {
  font-size: 11px; font-weight: 600;
  padding: 3px 10px; border-radius: 99px;
  background: var(--accent-soft);
  color: var(--accent);
  letter-spacing: 0.3px;
}
.prov-body { display: flex; align-items: center; gap: 18px; }
.ring-wrap {
  position: relative;
  width: 92px; height: 92px; flex-shrink: 0;
  display: flex; align-items: center; justify-content: center;
}
.ring {
  position: absolute; top: 0; left: 0;
  transition: transform 0.3s ease;
}
.ring-bg { stroke: var(--divider); }
.ring-arc {
  stroke: var(--accent);
  transition: stroke-dasharray 0.6s ease;
}
.ring-num {
  font-size: 23px; font-weight: 700;
  font-variant-numeric: tabular-nums;
  line-height: 1;
  margin-top: -6px;
}
.ring-cap {
  position: absolute; bottom: 18px;
  font-size: 9px; color: var(--text-faint);
  letter-spacing: 2px; text-transform: uppercase;
}
.prov-meta { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 10px; }
.prov-line {
  display: flex; align-items: center; gap: 10px;
  font-size: 13px; color: var(--text);
}
.prov-line-cap {
  color: var(--text-faint); font-size: 11px;
  width: 48px; flex-shrink: 0;
  letter-spacing: 0.2px;
}
.prov-line-val {
  color: var(--text); font-variant-numeric: tabular-nums;
  font-size: 13px;
}
.week-row .bar {
  flex: 1; height: 6px; border-radius: 3px;
  background: var(--divider);
  position: relative; overflow: hidden;
}
.week-row .bar-fill {
  display: block; height: 100%;
  background: var(--accent);
  border-radius: 3px;
  transition: width 0.6s ease;
}
.week-row .bar-pct {
  text-align: right; min-width: 36px;
}
.prov-err {
  margin-top: 10px;
  font-size: 11px; color: #D55;
  background: rgba(220,80,80,0.08);
  padding: 6px 8px; border-radius: 8px;
}

/* Quip card */
.quip-card {
  display: flex; align-items: flex-start; gap: 10px;
  padding: 14px 16px;
  background: linear-gradient(135deg, var(--claude-soft), var(--codex-soft));
}
.quip-pet { font-size: 18px; line-height: 1.3; }
.quip-text {
  flex: 1; font-size: 14px; line-height: 1.5;
  font-style: italic;
}

/* Stat card */
.stat-row { display: flex; gap: 18px; }
.stat { flex: 1; }
.stat-num {
  font-size: 30px; font-weight: 700;
  font-variant-numeric: tabular-nums;
  letter-spacing: 0.5px;
  line-height: 1.1;
}
.stat-cap {
  font-size: 11px; color: var(--text-faint);
  letter-spacing: 1.5px; text-transform: uppercase;
  margin-top: 4px;
}

/* Chart card */
.chart-card { padding: 16px 14px 14px; }
.seg {
  display: inline-flex; background: var(--divider);
  border-radius: 9px; padding: 2px;
}
.seg-btn {
  border: none; background: transparent;
  font-size: 12px; font-weight: 600;
  padding: 4px 12px; border-radius: 7px;
  color: var(--text-dim); cursor: pointer;
  font-family: inherit;
  transition: background 0.15s ease, color 0.15s ease;
}
.seg-btn.active {
  background: var(--card);
  color: var(--text);
  box-shadow: 0 1px 3px rgba(0,0,0,0.08);
}
.chart-wrap { margin-top: 6px; }
#chart rect { transition: y 0.4s ease, height 0.4s ease; }
.chart-axis {
  display: flex; justify-content: space-between;
  font-size: 10px; color: var(--text-faint);
  font-variant-numeric: tabular-nums;
  margin: 4px 4px 0;
}
.chart-axis span { flex: 1; text-align: center; }
.legend {
  margin-top: 10px;
  font-size: 11px; color: var(--text-dim);
  display: flex; align-items: center; gap: 4px;
}
.legend .dot {
  display: inline-block; width: 8px; height: 8px;
  border-radius: 4px; margin-right: 4px;
}
.legend .peak {
  margin-left: auto;
  color: var(--text-faint);
  font-variant-numeric: tabular-nums;
}

/* Renewal */
.renewal-row { display: flex; gap: 14px; }
.renewal-item { flex: 1; }
.renewal-tag {
  display: inline-block;
  font-size: 10px; font-weight: 700;
  padding: 2px 8px; border-radius: 99px;
  letter-spacing: 1.5px; text-transform: uppercase;
  margin-bottom: 6px;
}
.renewal-num {
  font-size: 22px; font-weight: 700;
  font-variant-numeric: tabular-nums;
  line-height: 1.1;
}
.renewal-cap {
  font-size: 11px; color: var(--text-faint);
  margin-top: 4px;
}

footer {
  font-size: 11px; color: var(--text-faint);
  text-align: center; padding: 8px 0 20px;
  letter-spacing: 0.5px;
}
footer .switch {
  display: inline-block; margin-left: 8px;
  color: var(--text-dim); text-decoration: none;
  border-bottom: 1px dotted var(--text-faint);
}
"""
