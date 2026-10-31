"""Reserve an illustration's result row before the cinema-caption band.

The caller declares which existing text layer belongs to which illustration.
Only rectangular layer geometry is edited; facts, timing, artwork, opacity,
voice and causal actions remain normal authored inputs. Native text shaping and
the actual production review are still required after this conservative fit.
"""
from copy import deepcopy
import math


class ResultLabelLayoutError(ValueError):
    pass


def need(ok, message):
    if not ok:
        raise ResultLabelLayoutError(message)


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def bounds(layer, width, height):
    """Conservative pixel envelope, including every authored rectangular pose."""
    need(all(number(layer.get(k)) for k in ('x', 'y', 'width', 'height'))
         and layer['width'] > 0 and layer['height'] > 0,
         'Story layers need finite positive rectangular geometry')
    poses = [dict(x=layer['x'], y=layer['y'], scale=1)] + layer.get('keyframes', [])
    rectangles = []
    for pose in poses:
        need(all(number(pose.get(k)) for k in ('x', 'y', 'scale')) and pose['scale'] > 0,
             'Every authored pose needs finite positive rectangular geometry')
        half_w = layer['width'] * pose['scale'] * width / 2
        half_h = layer['height'] * pose['scale'] * height / 2
        x, y = pose['x'] * width, pose['y'] * height
        rectangles.append((x - half_w, y - half_h, x + half_w, y + half_h))
    return (min(r[0] for r in rectangles), min(r[1] for r in rectangles),
            max(r[2] for r in rectangles), max(r[3] for r in rectangles))


def intersects(a, b):
    return a[0] < b[2] - 1e-7 and b[0] < a[2] - 1e-7 and a[1] < b[3] - 1e-7 and b[1] < a[3] - 1e-7


def reflow_result_labels(scene, result_layers, *, canvas_width=1280, canvas_height=720,
                         caption_top=610, result_height=52, illustration_gap=12,
                         caption_gap=12, horizontal_inset=16, safe_margin=24):
    """Keep the stage's size and give declared results one separate lower row.

    ``result_layers`` maps existing text-layer IDs to their illustration IDs.
    Pixel values use top-left canvas coordinates. The whole rectangular stage
    moves upward together; its x positions, dimensions and keyframe scales stay
    fixed. Results are then inset from their own illustration's actual envelope.
    Unusable space is rejected, rather than shrinking text or hiding a subject.
    The independent presenter is not a SceneLayer and is never transformed.
    """
    need(all(number(v) for v in (canvas_width, canvas_height, caption_top, result_height,
                                 illustration_gap, caption_gap, horizontal_inset, safe_margin))
         and canvas_width >= canvas_height > 0 and 0 < caption_top < canvas_height
         and result_height >= 48 and min(illustration_gap, caption_gap, horizontal_inset, safe_margin) >= 0,
         'A landscape canvas, 32pt text row and explicit nonnegative clearances are required')
    need(isinstance(result_layers, dict) and result_layers, 'Declare every result layer and its illustration')
    layers = scene.get('layers', [])
    need(isinstance(layers, list) and all(isinstance(l, dict) for l in layers)
         and len({l.get('id') for l in layers}) == len(layers), 'Existing unique story layers are required')
    by_id = {l['id']: l for l in layers}
    need(all(label in by_id and obstacle in by_id and label != obstacle
             for label, obstacle in result_layers.items()), 'Results must bind existing independent illustrations')
    need(not any(l.get('texturedPath') for l in layers), 'Textured paths require their own semantic layout')
    need(all(a.get('kind') in ('show', 'hide')
             and not any(k in a for k in ('from', 'to', 'waypoints'))
             for a in scene.get('storyActions', [])),
         'Positioned story actions require a coordinated layout; this fit only preserves show/hide actions')
    for label, obstacle in result_layers.items():
        need(by_id[label].get('kind') == '文字' and by_id[obstacle].get('kind') == '图片'
             and not by_id[label].get('keyframes') and by_id[obstacle].get('opacity', 1) > 0,
             'Each result needs a static text box and a visible rectangular illustration')
        need(isinstance(by_id[label].get('text'), str) and by_id[label]['text'].strip(),
             'A result must preserve its complete nonempty text')

    obstacles = {identity: bounds(by_id[identity], canvas_width, canvas_height)
                 for identity in set(result_layers.values())}
    # Reserve captions, then the complete 32pt result box, then the visual gap.
    row_top = caption_top - caption_gap - result_height
    visual_bottom = row_top - illustration_gap
    delta = visual_bottom - max(r[3] for r in obstacles.values())
    need(delta <= 1e-7, 'This fit only moves an existing stage upward; an already higher stage needs its own declared layout')
    result = deepcopy(scene)
    for layer in result['layers']:
        layer['y'] += delta / canvas_height
        for pose in layer.get('keyframes', []):
            pose['y'] += delta / canvas_height
    fitted = {l['id']: l for l in result['layers']}
    for label, obstacle in result_layers.items():
        left, _, right, _ = obstacles[obstacle]
        label_width = right - left - 2 * horizontal_inset
        # LayerPainter uses fixed 32pt landscape text. A whole-em allowance is
        # conservative for these short strings; native CoreText still checks it.
        need(label_width >= len(fitted[label]['text']) * 32,
             'The complete result cannot fit its own illustration column at the normal font size')
        fitted[label].update(x=(left + right) / 2 / canvas_width,
                             y=(row_top + result_height / 2) / canvas_height,
                             width=label_width / canvas_width, height=result_height / canvas_height)

    visible = {identity: bounds(layer, canvas_width, canvas_height)
               for identity, layer in fitted.items() if layer.get('opacity', 1) > 0}
    for identity, rect in visible.items():
        need(rect[0] >= safe_margin - 1e-7 and rect[1] >= safe_margin - 1e-7
             and rect[2] <= canvas_width - safe_margin + 1e-7
             and rect[3] <= canvas_height - safe_margin + 1e-7,
             'The stage cannot retain every visible subject inside the canvas safety margin')
        if identity in result_layers:
            need(rect[3] <= caption_top - caption_gap + 1e-7, 'A result enters the reserved cinema-caption band')
            for other, other_rect in visible.items():
                if other not in result_layers:
                    need(not intersects(rect, other_rect), 'A result overlaps an illustration or another story element')
    labels = list(result_layers)
    for i, identity in enumerate(labels):
        layer = fitted[identity]
        for other in labels[i + 1:]:
            next_layer = fitted[other]
            if layer['startFrame'] < next_layer['endFrame'] and next_layer['startFrame'] < layer['endFrame']:
                need(not intersects(visible[identity], visible[other]), 'Simultaneous result rows overlap')
    return result
