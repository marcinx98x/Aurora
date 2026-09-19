/* Aurora CAF custom receiver — lyrics | art + bottom controls */
(function () {
  const NAMESPACE = 'urn:x-cast:com.aurora.music';
  const context = cast.framework.CastReceiverContext.getInstance();
  const playerManager = context.getPlayerManager();

  const el = {
    app: document.getElementById('app'),
    lyrics: document.getElementById('lyrics'),
    title: document.getElementById('title'),
    artist: document.getElementById('artist'),
    artwork: document.getElementById('artwork'),
    artFallback: document.getElementById('art-fallback'),
    btnPrev: document.getElementById('btn-prev'),
    btnPlay: document.getElementById('btn-play'),
    btnNext: document.getElementById('btn-next'),
    progressTrack: document.getElementById('progress-track'),
    progressFill: document.getElementById('progress-fill'),
    timePos: document.getElementById('time-pos'),
    timeDur: document.getElementById('time-dur'),
  };

  let synced = [];
  let plain = '';
  let durationSec = 0;
  let tickTimer = null;

  function fmt(sec) {
    if (!isFinite(sec) || sec < 0) sec = 0;
    const s = Math.floor(sec % 60);
    const m = Math.floor(sec / 60) % 60;
    const h = Math.floor(sec / 3600);
    const pad = (n) => String(n).padStart(2, '0');
    return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
  }

  function sendCommand(action) {
    try {
      context.sendCustomMessage(NAMESPACE, undefined, { action: action });
    } catch (e) {
      console.warn('[aurora] sendCustomMessage', e);
    }
  }

  function setMarquee(text) {
    const safe = text || 'Aurora';
    const needsScroll = safe.length > 28;
    el.title.classList.toggle('scroll', needsScroll);
    if (needsScroll) {
      el.title.innerHTML = `<span>${escapeHtml(safe)}&nbsp;&nbsp;&nbsp;${escapeHtml(safe)}</span>`;
    } else {
      el.title.innerHTML = `<span>${escapeHtml(safe)}</span>`;
    }
  }

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function renderLyricsStructure() {
    el.lyrics.innerHTML = '';
    if (synced.length) {
      synced.forEach((line, i) => {
        const p = document.createElement('p');
        p.className = 'lyric-line';
        p.dataset.i = String(i);
        p.textContent = line.text || ' ';
        el.lyrics.appendChild(p);
      });
      return;
    }
    if (plain && plain.trim()) {
      const p = document.createElement('p');
      p.className = 'lyrics-plain';
      p.textContent = plain;
      el.lyrics.appendChild(p);
      return;
    }
    const empty = document.createElement('p');
    empty.className = 'lyrics-empty';
    empty.textContent = 'No lyrics';
    el.lyrics.appendChild(empty);
  }

  function activeIndexAt(t) {
    let active = -1;
    for (let i = 0; i < synced.length; i++) {
      if (synced[i].time <= t) active = i;
      else break;
    }
    return active;
  }

  function highlightLyrics(t) {
    if (!synced.length) return;
    const active = activeIndexAt(t);
    const nodes = el.lyrics.querySelectorAll('.lyric-line');
    nodes.forEach((node, i) => {
      node.classList.toggle('active', i === active);
      node.classList.toggle('near', i === active - 1 || i === active + 1);
    });
    const activeNode = el.lyrics.querySelector('.lyric-line.active');
    if (activeNode) {
      activeNode.scrollIntoView({ block: 'center', behavior: 'smooth' });
    }
  }

  function setArtwork(url, title) {
    if (url) {
      el.artwork.onload = () => {
        el.artwork.classList.add('visible');
        el.artFallback.classList.add('hidden');
      };
      el.artwork.onerror = () => {
        el.artwork.classList.remove('visible');
        el.artFallback.classList.remove('hidden');
        el.artFallback.textContent = (title || 'A').charAt(0).toUpperCase();
      };
      el.artwork.src = url;
    } else {
      el.artwork.removeAttribute('src');
      el.artwork.classList.remove('visible');
      el.artFallback.classList.remove('hidden');
      el.artFallback.textContent = (title || 'A').charAt(0).toUpperCase();
    }
  }

  function applyMetadata(media) {
    const meta = media && media.metadata ? media.metadata : {};
    const custom = (media && media.customData) || {};
    const title = custom.title || meta.title || 'Aurora';
    const artist = custom.artist || meta.artist || meta.subtitle || '';
    let artworkUrl = custom.artworkUrl || '';
    if (!artworkUrl && meta.images && meta.images.length) {
      artworkUrl = meta.images[0].url || '';
    }
    synced = Array.isArray(custom.synced)
      ? custom.synced.map((l) => ({
          time: Number(l.time) || 0,
          text: String(l.text || ''),
        }))
      : [];
    plain = custom.plain ? String(custom.plain) : '';
    durationSec = (media && media.duration) ? Number(media.duration) : 0;

    setMarquee(title);
    el.artist.textContent = artist;
    setArtwork(artworkUrl, title);
    renderLyricsStructure();
    el.app.classList.remove('idle');
  }

  function updateProgress() {
    try {
      const t = playerManager.getCurrentTimeSec() || 0;
      const d = playerManager.getDurationSec() || durationSec || 0;
      durationSec = d;
      const pct = d > 0 ? Math.min(100, (t / d) * 100) : 0;
      el.progressFill.style.width = pct + '%';
      el.timePos.textContent = fmt(t);
      el.timeDur.textContent = fmt(d);
      highlightLyrics(t);
      const state = playerManager.getPlayerState();
      const playing = state === cast.framework.messages.PlayerState.PLAYING;
      el.btnPlay.innerHTML = playing ? '&#10073;&#10073;' : '&#9654;';
    } catch (_) { /* ignore */ }
  }

  function startTicker() {
    if (tickTimer) clearInterval(tickTimer);
    tickTimer = setInterval(updateProgress, 250);
  }

  playerManager.setMessageInterceptor(
    cast.framework.messages.MessageType.LOAD,
    (loadRequestData) => {
      try {
        applyMetadata(loadRequestData.media);
      } catch (e) {
        console.warn('[aurora] applyMetadata', e);
      }
      return loadRequestData;
    }
  );

  playerManager.addEventListener(
    cast.framework.events.EventType.MEDIA_STATUS,
    () => updateProgress()
  );
  playerManager.addEventListener(
    cast.framework.events.EventType.PLAYER_LOAD_COMPLETE,
    () => {
      updateProgress();
      startTicker();
    }
  );

  el.btnPlay.addEventListener('click', () => {
    const state = playerManager.getPlayerState();
    if (state === cast.framework.messages.PlayerState.PLAYING) {
      playerManager.pause();
    } else {
      playerManager.play();
    }
  });
  el.btnPrev.addEventListener('click', () => sendCommand('previous'));
  el.btnNext.addEventListener('click', () => sendCommand('next'));

  el.progressTrack.addEventListener('click', (ev) => {
    const rect = el.progressTrack.getBoundingClientRect();
    const ratio = Math.max(0, Math.min(1, (ev.clientX - rect.left) / rect.width));
    const d = playerManager.getDurationSec() || durationSec || 0;
    if (d > 0) playerManager.seek(ratio * d);
  });

  context.addCustomMessageListener(NAMESPACE, () => {
    /* sender → receiver reserved for future */
  });

  const options = new cast.framework.CastReceiverOptions();
  options.disableIdleTimeout = true;
  options.customNamespaces = Object.assign({}, options.customNamespaces || {}, {
    [NAMESPACE]: cast.framework.system.MessageType.JSON,
  });
  context.start(options);
  startTicker();
})();
