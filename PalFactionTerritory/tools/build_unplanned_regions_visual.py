from __future__ import annotations

import base64
import json
import sys
from pathlib import Path

from PIL import Image


def data_url(path: Path) -> str:
    suffix = path.suffix.lower()
    mime = "image/jpeg" if suffix in {".jpg", ".jpeg"} else "image/png"
    return f"data:{mime};base64,{base64.b64encode(path.read_bytes()).decode('ascii')}"


def native_region(marker: dict[str, object], regions: list[dict[str, object]], mask_dir: Path) -> str | None:
    x = float(marker["x"])
    y = float(marker["y"])
    best_id: str | None = None
    best_alpha = 0
    for region in regions:
        mask_path = mask_dir / f"{region['asset']}.png"
        with Image.open(mask_path) as image:
            rgba = image.convert("RGBA")
            px = round((rgba.width - 1) * x / 100)
            py = round((rgba.height - 1) * y / 100)
            alpha = rgba.getpixel((px, py))[3]
        if alpha > best_alpha:
            best_alpha = alpha
            best_id = str(region["id"])
    return best_id if best_alpha > 0 else None


def main() -> int:
    if len(sys.argv) != 4:
        raise SystemExit(
            "Usage: build_unplanned_regions_visual.py <project-root> <output-fragment> <output-evidence>"
        )

    project_root = Path(sys.argv[1]).resolve()
    output_fragment = Path(sys.argv[2]).resolve()
    output_evidence = Path(sys.argv[3]).resolve()
    artifacts = project_root / "artifacts"
    mask_dir = artifacts / "map-assets" / "masks"

    planning = json.loads(
        (project_root / "evidence" / "map_planning_markers.v1.json").read_text(encoding="utf-8")
    )
    assignments = json.loads(
        (project_root / "contracts" / "territory_assignments.v1.json").read_text(encoding="utf-8")
    )["assignments"]
    assigned_ids = {item["regionId"] for item in assignments}
    excluded_ids = {"M-T"}
    unplanned = [
        region
        for region in planning["mainRegions"]
        if region["id"] not in assigned_ids and region["id"] not in excluded_ids
    ]
    unplanned_ids = {region["id"] for region in unplanned}

    def attach_region(items: list[dict[str, object]]) -> list[dict[str, object]]:
        result: list[dict[str, object]] = []
        for item in items:
            region_id = native_region(item, planning["mainRegions"], mask_dir)
            if region_id in unplanned_ids:
                result.append({**item, "regionId": region_id})
        return result

    towers = attach_region([item for item in planning["towers"] if item.get("mapId") == "main"])
    alphas = attach_region(planning["wildAlphaBosses"])
    settlements = attach_region(planning.get("humanSettlements", []))
    regions = [
        {
            "id": region["id"],
            "asset": region["asset"],
            "x": region["x"],
            "y": region["y"],
            "mask": data_url(mask_dir / f"{region['asset']}.png"),
            "towerCount": sum(item["regionId"] == region["id"] for item in towers),
            "alphaCount": sum(item["regionId"] == region["id"] for item in alphas),
            "settlementCount": sum(item["regionId"] == region["id"] for item in settlements),
        }
        for region in unplanned
    ]
    dataset = {
        "generatedAt": "2026-07-21",
        "excluded": ["M-T", "T-A", "T-B"],
        "assigned": sorted(assigned_ids),
        "regions": regions,
        "towers": towers,
        "alphas": alphas,
        "settlements": settlements,
        "baseMap": data_url(artifacts / "map-assets" / "native-world-map.jpg"),
    }

    output_evidence.parent.mkdir(parents=True, exist_ok=True)
    output_evidence.write_text(
        json.dumps(
            {
                "generatedAt": dataset["generatedAt"],
                "excluded": dataset["excluded"],
                "assigned": dataset["assigned"],
                "unplannedRegionIds": [region["id"] for region in regions],
                "counts": {
                    "regions": len(regions),
                    "towers": len(towers),
                    "wildAlphaBosses": len(alphas),
                    "humanSettlements": len(settlements),
                },
                "regions": [
                    {key: value for key, value in region.items() if key != "mask"}
                    for region in regions
                ],
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    payload = json.dumps(dataset, ensure_ascii=False, separators=(",", ":"))
    fragment = f'''<div id="pw-unplanned-20260721">
  <style>
    #pw-unplanned-20260721 {{ color:var(--foreground); }}
    #pw-unplanned-20260721 .pw-controls {{ display:flex; align-items:center; justify-content:space-between; gap:8px; flex-wrap:wrap; margin-bottom:8px; }}
    #pw-unplanned-20260721 .pw-map {{ position:relative; width:min(100%,820px); aspect-ratio:1; margin:0 auto; overflow:hidden; background:var(--muted); touch-action:none; }}
    #pw-unplanned-20260721 .pw-canvas {{ position:absolute; inset:0; transform-origin:50% 50%; }}
    #pw-unplanned-20260721 .pw-base {{ position:absolute; inset:0; width:100%; height:100%; object-fit:contain; user-select:none; pointer-events:none; }}
    #pw-unplanned-20260721 .pw-fill,
    #pw-unplanned-20260721 .pw-edge {{ position:absolute; inset:0; width:100%; height:100%; pointer-events:none; }}
    #pw-unplanned-20260721 .pw-fill {{ background:var(--viz-series-3); opacity:.22; -webkit-mask-size:contain; -webkit-mask-repeat:no-repeat; mask-size:contain; mask-repeat:no-repeat; }}
    #pw-unplanned-20260721 .pw-fill.is-selected {{ background:var(--viz-series-1); opacity:.44; }}
    #pw-unplanned-20260721 .pw-edge {{ object-fit:contain; opacity:.72; filter:grayscale(1) brightness(1.7) contrast(1.45) drop-shadow(1px 0 0 var(--viz-series-3)) drop-shadow(-1px 0 0 var(--viz-series-3)) drop-shadow(0 1px 0 var(--viz-series-3)) drop-shadow(0 -1px 0 var(--viz-series-3)); }}
    #pw-unplanned-20260721 .pw-edge.is-selected {{ opacity:1; filter:grayscale(1) brightness(1.8) contrast(1.5) drop-shadow(2px 0 0 var(--viz-series-1)) drop-shadow(-2px 0 0 var(--viz-series-1)) drop-shadow(0 2px 0 var(--viz-series-1)) drop-shadow(0 -2px 0 var(--viz-series-1)); }}
    #pw-unplanned-20260721 .pw-label,
    #pw-unplanned-20260721 .pw-marker {{ position:absolute; transform:translate(-50%,-50%); pointer-events:auto; }}
    #pw-unplanned-20260721 .pw-label {{ z-index:5; font-weight:500; }}
    #pw-unplanned-20260721 .pw-marker {{ z-index:7; padding:0; min-width:0; min-height:0; border-radius:50%; }}
    #pw-unplanned-20260721 .pw-marker.alpha {{ width:10px; height:10px; background:var(--viz-series-2); border:2px solid var(--background); }}
    #pw-unplanned-20260721 .pw-marker.tower {{ width:24px; height:24px; display:grid; place-items:center; background:var(--viz-series-1); color:var(--background); border:2px solid var(--background); font-weight:500; }}
    #pw-unplanned-20260721 .pw-marker.settlement {{ width:20px; height:20px; display:grid; place-items:center; border-radius:4px; background:var(--viz-series-4); color:var(--background); border:2px solid var(--background); font-weight:500; }}
    #pw-unplanned-20260721 .pw-marker.is-dim {{ display:none; }}
    #pw-unplanned-20260721 .pw-detail {{ margin-top:8px; }}
    #pw-unplanned-20260721 .pw-legend {{ display:flex; gap:12px; align-items:center; flex-wrap:wrap; margin-top:8px; color:var(--muted-foreground); }}
    #pw-unplanned-20260721 .pw-dot {{ width:9px; height:9px; border-radius:50%; background:var(--viz-series-2); display:inline-block; }}
    #pw-unplanned-20260721 .pw-line {{ width:22px; border-top:3px solid var(--viz-series-3); display:inline-block; }}
    #pw-unplanned-20260721 .pw-legend-item {{ display:inline-flex; align-items:center; gap:5px; }}
    @media (prefers-reduced-motion:reduce) {{ #pw-unplanned-20260721 .pw-canvas {{ transition:none; }} }}
  </style>
  <div class="pw-controls">
    <div class="viz-controls" aria-label="地图图层">
      <button class="btn btn-primary" id="pwUnplannedBossToggle" type="button" aria-pressed="true">野外 Boss</button>
      <button class="btn" id="pwUnplannedZoomOut" type="button" aria-label="缩小地图">−</button>
      <button class="btn" id="pwUnplannedZoomReset" type="button" aria-label="恢复地图缩放">100%</button>
      <button class="btn" id="pwUnplannedZoomIn" type="button" aria-label="放大地图">＋</button>
    </div>
    <span class="viz-badge">剩余 {len(regions)} 区</span>
  </div>
  <div class="pw-map" id="pwUnplannedMap" role="img" aria-label="除 M-T 和世界树外尚未规划势力的主世界地块">
    <div class="pw-canvas" id="pwUnplannedCanvas">
      <img class="pw-base" alt="幻兽帕鲁主世界地图" src="{dataset['baseMap']}">
      <div id="pwUnplannedRegionLayer"></div>
      <div id="pwUnplannedMarkerLayer"></div>
    </div>
  </div>
  <div class="card pw-detail" aria-live="polite">
    <span id="pwUnplannedDetail">点击地块编号查看该区仍保留的塔主、Boss 与城镇数量。</span>
  </div>
  <div class="pw-legend text-small">
    <span class="pw-legend-item"><span class="pw-line"></span>未规划地块边界</span>
    <span class="pw-legend-item"><span class="pw-dot"></span>该地块内野外 Alpha Boss</span>
    <span class="pw-legend-item">已排除 M-T、T-A、T-B</span>
    <span class="pw-legend-item">支持 100%–300% 缩放与拖动</span>
  </div>
  <script>
    (() => {{
      const root = document.getElementById('pw-unplanned-20260721');
      const data = {payload};
      const map = root.querySelector('#pwUnplannedMap');
      const canvas = root.querySelector('#pwUnplannedCanvas');
      const regionLayer = root.querySelector('#pwUnplannedRegionLayer');
      const markerLayer = root.querySelector('#pwUnplannedMarkerLayer');
      const detail = root.querySelector('#pwUnplannedDetail');
      const zoomReset = root.querySelector('#pwUnplannedZoomReset');
      let selected = null;
      let bossesVisible = true;
      let zoom = 1;
      let panX = 0;
      let panY = 0;

      function applyTransform() {{
        const maxPan = map.clientWidth * (zoom - 1) / (2 * zoom);
        panX = Math.max(-maxPan, Math.min(maxPan, panX));
        panY = Math.max(-maxPan, Math.min(maxPan, panY));
        canvas.style.transform = 'scale(' + zoom + ') translate(' + panX + 'px,' + panY + 'px)';
        map.style.cursor = zoom > 1 ? 'grab' : '';
      }}
      function setZoom(next) {{
        zoom = Math.max(1, Math.min(3, Math.round(next * 4) / 4));
        if (zoom === 1) {{ panX = 0; panY = 0; }}
        zoomReset.textContent = Math.round(zoom * 100) + '%';
        applyTransform();
      }}
      function chooseRegion(region) {{
        selected = region.id;
        root.querySelectorAll('[data-region]').forEach(el => el.classList.toggle('is-selected', el.dataset.region === selected));
        detail.textContent = region.id + ' · 塔主 ' + region.towerCount + ' · 野外 Alpha Boss ' + region.alphaCount + ' · 人类城镇 ' + region.settlementCount;
      }}
      regionLayer.innerHTML = data.regions.map(region =>
        '<div class="pw-fill" data-region="' + region.id + '" style="-webkit-mask-image:url(' + region.mask + ');mask-image:url(' + region.mask + ')"></div>' +
        '<img class="pw-edge" data-region="' + region.id + '" src="' + region.mask + '" alt="">' +
        '<button class="btn pw-label" type="button" data-region="' + region.id + '" style="left:' + region.x + '%;top:' + region.y + '%" aria-label="选择未规划地块 ' + region.id + '">' + region.id + '</button>'
      ).join('');
      root.querySelectorAll('.pw-label').forEach(button => button.addEventListener('click', () => chooseRegion(data.regions.find(region => region.id === button.dataset.region))));

      function markerButton(marker, kind) {{
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'pw-marker ' + kind;
        button.style.left = marker.x + '%';
        button.style.top = marker.y + '%';
        button.dataset.region = marker.regionId;
        if (kind === 'tower') button.textContent = marker.id.slice(1);
        if (kind === 'settlement') button.textContent = '城';
        const label = kind === 'tower' ? marker.leader + ' & ' + marker.pal : marker.zh + ' / ' + marker.en;
        button.dataset.tooltip = label;
        button.setAttribute('aria-label', label + '，位于 ' + marker.regionId);
        button.addEventListener('click', () => {{
          chooseRegion(data.regions.find(region => region.id === marker.regionId));
          detail.textContent = marker.regionId + ' · ' + label + (kind === 'alpha' ? ' · Lv.' + marker.level : '');
        }});
        markerLayer.appendChild(button);
      }}
      data.alphas.forEach(marker => markerButton(marker, 'alpha'));
      data.towers.forEach(marker => markerButton(marker, 'tower'));
      data.settlements.forEach(marker => markerButton(marker, 'settlement'));

      root.querySelector('#pwUnplannedBossToggle').addEventListener('click', event => {{
        bossesVisible = !bossesVisible;
        event.currentTarget.setAttribute('aria-pressed', String(bossesVisible));
        event.currentTarget.classList.toggle('btn-primary', bossesVisible);
        root.querySelectorAll('.pw-marker.alpha').forEach(el => el.classList.toggle('is-dim', !bossesVisible));
      }});
      root.querySelector('#pwUnplannedZoomOut').addEventListener('click', () => setZoom(zoom - .25));
      root.querySelector('#pwUnplannedZoomIn').addEventListener('click', () => setZoom(zoom + .25));
      zoomReset.addEventListener('click', () => setZoom(1));
      map.addEventListener('wheel', event => {{ event.preventDefault(); setZoom(zoom + (event.deltaY < 0 ? .25 : -.25)); }}, {{ passive:false }});
      let drag = null;
      map.addEventListener('pointerdown', event => {{
        if (zoom === 1 || event.target.closest('button')) return;
        drag = {{ id:event.pointerId, x:event.clientX, y:event.clientY, panX, panY }};
        map.setPointerCapture(event.pointerId);
      }});
      map.addEventListener('pointermove', event => {{
        if (!drag || drag.id !== event.pointerId) return;
        panX = drag.panX + (event.clientX - drag.x) / zoom;
        panY = drag.panY + (event.clientY - drag.y) / zoom;
        applyTransform();
        map.style.cursor = 'grabbing';
      }});
      function endDrag(event) {{ if (drag?.id === event.pointerId) drag = null; }}
      map.addEventListener('pointerup', endDrag);
      map.addEventListener('pointercancel', endDrag);
    }})();
  </script>
</div>
'''
    output_fragment.parent.mkdir(parents=True, exist_ok=True)
    output_fragment.write_text(fragment, encoding="utf-8")
    print(json.dumps({"unplanned": [region["id"] for region in regions], "fragmentBytes": output_fragment.stat().st_size}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
