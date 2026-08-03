(() => {
  const root = document.documentElement;
  const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

  const revealImmediately = () => {
    document.querySelectorAll('[data-reveal]').forEach((element) => {
      element.classList.add('is-visible');
    });
  };

  if (prefersReducedMotion.matches || !('IntersectionObserver' in window)) {
    revealImmediately();
  } else {
    const observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add('is-visible');
        observer.unobserve(entry.target);
      });
    }, {
      threshold: 0.14,
      rootMargin: '0px 0px -7% 0px'
    });

    document.querySelectorAll('[data-reveal]:not([data-reveal="hero"])').forEach((element) => {
      observer.observe(element);
    });

    requestAnimationFrame(() => {
      document.querySelectorAll('[data-reveal="hero"]').forEach((element) => {
        element.classList.add('is-visible');
      });
    });
  }

  const finePointer = window.matchMedia('(pointer: fine)');
  if (!prefersReducedMotion.matches && finePointer.matches) {
    const hero = document.querySelector('.parallax-zone');
    const tiltCard = document.querySelector('[data-tilt]');

    if (hero) {
      let frame = 0;
      hero.addEventListener('pointermove', (event) => {
        if (frame) cancelAnimationFrame(frame);
        frame = requestAnimationFrame(() => {
          const rect = hero.getBoundingClientRect();
          const x = (event.clientX - rect.left) / rect.width;
          const y = (event.clientY - rect.top) / rect.height;
          root.style.setProperty('--pointer-x', `${Math.round(x * 100)}%`);
          root.style.setProperty('--pointer-y', `${Math.round(y * 100)}%`);

          if (tiltCard) {
            tiltCard.style.setProperty('--tilt-x', `${(0.5 - y) * 5}deg`);
            tiltCard.style.setProperty('--tilt-y', `${(x - 0.5) * 7}deg`);
          }
        });
      });

      hero.addEventListener('pointerleave', () => {
        if (!tiltCard) return;
        tiltCard.style.setProperty('--tilt-x', '0deg');
        tiltCard.style.setProperty('--tilt-y', '0deg');
      });
    }
  }

  prefersReducedMotion.addEventListener?.('change', (event) => {
    if (!event.matches) return;
    revealImmediately();
    root.style.removeProperty('--pointer-x');
    root.style.removeProperty('--pointer-y');
  });
})();
