const RELABEL: Record<string, string> = {
  엘레베이터: '엘베',
  우편함실: '우편실',
};

const SVGNS = 'http://www.w3.org/2000/svg';

export function relabelSvg(svgEl: SVGSVGElement) {
  const screenCTM = svgEl.getScreenCTM();
  if (!screenCTM) return;
  const inv = screenCTM.inverse();
  const scale = screenCTM.a || 1;

  const toUser = (cx: number, cy: number) => {
    const p = svgEl.createSVGPoint();
    p.x = cx;
    p.y = cy;
    return p.matrixTransform(inv);
  };

  for (const [oldName, newName] of Object.entries(RELABEL)) {
    const nodes = svgEl.querySelectorAll<SVGGraphicsElement>(
      `[id="${oldName}"], [id^="${oldName}_"]`,
    );
    nodes.forEach((el) => {
      if (el.dataset.relabeled) return;
      const r = el.getBoundingClientRect();
      if (!r.width) return;

      const bl = toUser(r.left + r.width / 2, r.bottom);
      el.style.display = 'none';
      el.dataset.relabeled = '1';

      const t = document.createElementNS(SVGNS, 'text');
      t.textContent = newName;
      t.setAttribute('x', String(bl.x));
      t.setAttribute('y', String(bl.y));
      t.setAttribute('text-anchor', 'middle');
      t.setAttribute('font-size', String(r.height / scale));
      t.setAttribute('class', 'map-relabel');
      svgEl.appendChild(t);
    });
  }
}
