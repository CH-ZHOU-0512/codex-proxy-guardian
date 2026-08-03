(() => {
  const root = document.documentElement;
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const revealNodes = [...document.querySelectorAll('[data-reveal]')];
  const timeline = document.querySelector('[data-timeline]');

  const revealEverything = () => {
    revealNodes.forEach((node) => node.classList.add('is-visible'));
    if (timeline) {
      timeline.classList.add('is-active');
      timeline.style.setProperty('--timeline-progress', '1');
    }
  };

  if (reducedMotion.matches || !('IntersectionObserver' in window)) {
    revealEverything();
  } else {
    const revealObserver = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add('is-visible');
        revealObserver.unobserve(entry.target);
      });
    }, {
      threshold: 0.12,
      rootMargin: '0px 0px -6% 0px'
    });

    revealNodes.forEach((node) => revealObserver.observe(node));

    if (timeline) {
      const timelineObserver = new IntersectionObserver((entries) => {
        if (!entries.some((entry) => entry.isIntersecting)) return;
        timeline.classList.add('is-active');
        timeline.style.setProperty('--timeline-progress', '1');
        timelineObserver.disconnect();
      }, { threshold: 0.25 });
      timelineObserver.observe(timeline);
    }
  }

  let ticking = false;
  const updateProgress = () => {
    const available = document.documentElement.scrollHeight - window.innerHeight;
    const progress = available > 0 ? Math.min(1, Math.max(0, window.scrollY / available)) : 0;
    root.style.setProperty('--page-progress', progress.toFixed(4));
    ticking = false;
  };

  const requestProgressUpdate = () => {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(updateProgress);
  };

  updateProgress();
  window.addEventListener('scroll', requestProgressUpdate, { passive: true });
  window.addEventListener('resize', requestProgressUpdate, { passive: true });

  reducedMotion.addEventListener?.('change', (event) => {
    if (event.matches) revealEverything();
  });
})();
