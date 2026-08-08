(() => {
  const root = document.documentElement;
  const body = document.body;
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const revealNodes = [...document.querySelectorAll('[data-reveal]')];
  const nav = document.querySelector('[data-nav]');
  const navToggle = document.querySelector('[data-nav-toggle]');
  const navLinks = [...document.querySelectorAll('[data-nav] a[href^="#"]')];
  const sections = navLinks
    .map((link) => document.querySelector(link.getAttribute('href')))
    .filter(Boolean);

  const revealEverything = () => {
    revealNodes.forEach((node) => node.classList.add('is-visible'));
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
      rootMargin: '0px 0px -7% 0px'
    });

    revealNodes.forEach((node) => revealObserver.observe(node));
  }

  const setNavOpen = (open) => {
    if (!nav || !navToggle) return;
    nav.classList.toggle('is-open', open);
    navToggle.setAttribute('aria-expanded', String(open));
    navToggle.setAttribute('aria-label', open ? '关闭导航' : '打开导航');
    body.classList.toggle('nav-open', open && window.innerWidth <= 1040);
  };

  navToggle?.addEventListener('click', () => {
    setNavOpen(navToggle.getAttribute('aria-expanded') !== 'true');
  });

  navLinks.forEach((link) => {
    link.addEventListener('click', () => setNavOpen(false));
  });

  document.addEventListener('click', (event) => {
    if (!nav?.classList.contains('is-open')) return;
    if (nav.contains(event.target) || navToggle?.contains(event.target)) return;
    setNavOpen(false);
  });

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') setNavOpen(false);
  });

  const updateActiveNav = () => {
    if (!sections.length) return;
    const marker = window.scrollY + 150;
    let activeId = '';

    sections.forEach((section) => {
      if (section.offsetTop <= marker) activeId = section.id;
    });

    if (window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 8) {
      activeId = sections[sections.length - 1].id;
    }

    navLinks.forEach((link) => {
      const active = link.getAttribute('href') === `#${activeId}`;
      link.classList.toggle('is-active', active);
      if (active) link.setAttribute('aria-current', 'location');
      else link.removeAttribute('aria-current');
    });
  };

  let ticking = false;
  const updatePage = () => {
    const available = document.documentElement.scrollHeight - window.innerHeight;
    const progress = available > 0 ? Math.min(1, Math.max(0, window.scrollY / available)) : 0;
    root.style.setProperty('--page-progress', progress.toFixed(4));
    updateActiveNav();
    ticking = false;
  };

  const requestPageUpdate = () => {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(updatePage);
  };

  updatePage();
  window.addEventListener('scroll', requestPageUpdate, { passive: true });
  window.addEventListener('resize', () => {
    if (window.innerWidth > 1040) setNavOpen(false);
    requestPageUpdate();
  }, { passive: true });

  reducedMotion.addEventListener?.('change', (event) => {
    if (event.matches) revealEverything();
  });
})();
