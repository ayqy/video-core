"""Grounded motion for explicit, already imported character atlas poses.

The caller supplies real crop/anchor metadata, positions and finite source
frames. Anchors remain authored/inferred metadata, not image recognition or a
claim of visual acceptance. This module neither loads/generates images nor
reads rules, source traces, money amounts, ownership or causal bindings.

``ActorTrack.layer()`` emits an ordinary editable image layer. ``follow_path``
emits scene-coordinate anchor samples so the author can retain hand contact.
If that object already has a StoryAction move/transfer, native presentation
keeps its final position and overrides layer position keyframes. Follow-up
holding/putting-down must therefore use ordinary, unbound ``move`` actions
after the original business transfer. Do not create another delivery/payment
binding for a visual substep or demote the original business transfer.
"""
from __future__ import annotations

from copy import deepcopy
import math
import re

from scene_layout import sample_path


class ActorMotionError(ValueError):
    pass


def _need(condition, message):
    if not condition:
        raise ActorMotionError(message)


def _number(value):
    return type(value) in (int, float) and math.isfinite(value)


def _point(value, label, *, bounded=True):
    _need(isinstance(value, (tuple, list)) and len(value) == 2
          and all(_number(v) and (not bounded or 0 <= v <= 1) for v in value),
          'explicit finite ' + label + ' coordinates are required')
    return tuple(float(v) for v in value)


def _identity(value):
    return isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9._/-]{1,128}', value) is not None


def _same(left, right):
    return all(abs(a-b) <= 1e-10 for a, b in zip(left, right))


class ActorTrack:
    """A pose timeline and continuous foot route on a caller-selected canvas.

    ``frames`` is an actor's actual manifest pose map: each row supplies
    source_rect, source_pixel_rect and anchors including foot. Pose anchors use
    fractions inside that crop; the renderer fits the crop to ``box`` before
    applying the per-pose scale. ``foot_drop`` fixes the scene-height distance
    from image-box center to the foot, avoiding a jump when crop ratios change.
    ``flip_horizontal`` mirrors each fitted crop and its geometric anchors;
    the original atlas coordinates and source metadata remain unchanged.
    All time windows are start-inclusive/end-exclusive source frames.
    """
    def __init__(self, subject_id, asset_id, frames, *, duration, fps=30,
                 viewport=(1280, 720), box=(.30, .54), foot_drop=.22,
                 initial_foot=(.3, .73), default_pose='idle', flip_horizontal=False):
        _need(_identity(subject_id) and _identity(asset_id), 'explicit normal layer and asset identities are required')
        _need(type(duration) is int and 1 <= duration <= 54000
              and type(fps) is int and 1 <= fps <= 120, 'invalid finite actor source duration or fps')
        _need(isinstance(viewport, (tuple, list)) and len(viewport) == 2
              and all(type(v) is int and 1 <= v <= 16384 for v in viewport),
              'an explicit positive pixel viewport is required')
        box = _point(box, 'actor box')
        _need(all(.01 <= v <= 1 for v in box) and _number(foot_drop) and 0 < foot_drop <= .5,
              'positive bounded actor box and foot drop are required')
        _need(isinstance(frames, dict) and 1 <= len(frames) <= 64 and default_pose in frames,
              'explicit actual atlas poses and an existing default pose are required')
        _need(type(flip_horizontal) is bool, 'horizontal image flip must be an explicit Boolean')
        self.subject_id, self.asset_id = subject_id, asset_id
        self.duration, self.fps, self.viewport, self.box = duration, fps, tuple(viewport), box
        self.foot_drop, self.initial_foot = float(foot_drop), _point(initial_foot, 'initial foot')
        self.frames, self.default_pose = deepcopy(frames), default_pose
        self.flip_horizontal = flip_horizontal
        self._poses, self._moves = [], []
        for name, row in self.frames.items():
            _need(_identity(name) and isinstance(row, dict), 'every actual atlas pose needs an explicit identity')
            pixels, rect, anchors = row.get('source_pixel_rect'), row.get('source_rect'), row.get('anchors')
            _need(isinstance(pixels, (tuple, list)) and len(pixels) == 4
                  and all(type(v) is int and v >= 0 for v in pixels) and pixels[2] > 0 and pixels[3] > 0,
                  'pose crop pixel dimensions must be explicit positive integers')
            _need(isinstance(rect, dict) and set(rect) == {'x','y','width','height'}
                  and all(_number(v) for v in rect.values()) and rect['x'] >= 0 and rect['y'] >= 0
                  and rect['width'] > 0 and rect['height'] > 0
                  and rect['x'] + rect['width'] <= 1 + 1e-12 and rect['y'] + rect['height'] <= 1 + 1e-12,
                  'each actual pose needs its complete normalized atlas crop')
            _need(isinstance(anchors, dict) and 'foot' in anchors and len(anchors) <= 32,
                  'each actual pose needs its authored crop-local foot anchor')
            for anchor, point in anchors.items():
                _need(_identity(anchor), 'invalid explicit pose anchor identity')
                _point(point, 'crop-local ' + anchor)
            _need(anchors['foot'][1] > .5, 'the explicit foot must be below the pose center')
            if 'visible_pixel_bounds' in row:
                bounds = row['visible_pixel_bounds']
                _need(isinstance(bounds, (tuple, list)) and len(bounds) == 4
                      and all(_number(v) for v in bounds)
                      and 0 <= bounds[0] <= bounds[2] <= pixels[2]
                      and 0 <= bounds[1] <= bounds[3] <= pixels[3], 'visible pose bounds exceed the real crop')
            self._geometry(name, self.initial_foot)

    def _window(self, start, end):
        _need(type(start) is int and type(end) is int and 0 <= start < end <= self.duration,
              'actor windows must lie on the finite source frame axis')

    def pose(self, start, end, name):
        self._window(start, end)
        _need(_identity(name) and name in self.frames, 'the requested actual pose is absent from this actor atlas')
        _need(len(self._poses) < 512 and all(end <= a or start >= b for a, b, _ in self._poses),
              'actual pose windows overlap or exceed the finite sequence budget')
        self._poses.append((start, end, name))
        return self

    def walk(self, start, end, *, stride=4):
        self._window(start, end)
        _need(type(stride) is int and 1 <= stride <= self.duration
              and {'walk_left','walk_right'} <= self.frames.keys(),
              'walking needs a positive stride and two actual walking poses')
        windows = [(at, min(end, at+stride), 'walk_left' if i % 2 == 0 else 'walk_right')
                   for i, at in enumerate(range(start, end, stride))]
        _need(len(self._poses) + len(windows) <= 512
              and all(b <= x or a >= y for a,b,_ in windows for x,y,_ in self._poses),
              'walking pose windows overlap or exceed the finite sequence budget')
        self._poses.extend(windows)
        return self

    def move(self, start, end, start_foot, end_foot, *, waypoints=()):
        """Append one continuous foot route, using native arc-length sampling.

        Windows are chronological and nonoverlapping. The start must touch the
        prior held foot position; a branch reset needs explicitly authored
        separate visibility/staging rather than an accidental actor teleport.
        """
        self._window(start, end)
        start_foot, end_foot = _point(start_foot, 'route start foot'), _point(end_foot, 'route end foot')
        _need(isinstance(waypoints, (tuple, list)) and len(waypoints) <= 32,
              'a foot route has at most 32 explicit waypoints')
        points = [start_foot] + [_point(p, 'foot waypoint') for p in waypoints] + [end_foot]
        _need(len(self._moves) < 256 and (not self._moves or start >= self._moves[-1][1]),
              'foot routes must be finite, chronological and nonoverlapping')
        _need(_same(start_foot, self.foot_at(start)), 'the route start does not touch the actor previous held foot')
        self._moves.append((start, end, points))
        return self

    def foot_at(self, frame):
        _need(type(frame) is int and 0 <= frame < self.duration, 'foot sample lies outside the actual source axis')
        foot = self.initial_foot
        for start, end, points in self._moves:
            if frame < start:
                break
            if frame >= end:
                foot = points[-1]
            else:
                progress = min(1, max(0, (frame-start) / max(1, end-start-1)))
                row = sample_path([dict(x=x,y=y) for x,y in points], progress)
                return row['x'], row['y']
        return foot

    def pose_at(self, frame):
        _need(type(frame) is int and 0 <= frame < self.duration, 'pose sample lies outside the actual source axis')
        return next((name for start,end,name in self._poses if start <= frame < end), self.default_pose)

    def _geometry(self, pose, foot):
        row = self.frames[pose]
        _, _, width, height = row['source_pixel_rect']
        viewport_w, viewport_h = self.viewport
        fit = min(self.box[0] * viewport_w / width, self.box[1] * viewport_h / height)
        source_foot = row['anchors']['foot']
        scale = self.foot_drop * viewport_h / ((source_foot[1]-.5) * height * fit)
        _need(math.isfinite(scale) and .1 <= scale <= 4,
              'the grounded actual pose exceeds the native layer scale range')
        fit *= scale
        direction = -1 if self.flip_horizontal else 1
        center = (foot[0]-direction*(source_foot[0]-.5)*width*fit/viewport_w, foot[1]-self.foot_drop)
        return center, scale, fit

    def anchor(self, name, frame=0, *, pose=None, foot=None):
        """Sample an actual crop-local anchor in normalized scene coordinates."""
        _need(type(frame) is int and 0 <= frame < self.duration,
              'anchor sample lies outside the actual source axis')
        selected = self.pose_at(frame) if pose is None else pose
        _need(_identity(selected) and selected in self.frames and _identity(name)
              and name in self.frames[selected]['anchors'],
              'the selected actual actor pose has no requested anchor')
        foot = self.foot_at(frame) if foot is None else _point(foot, 'explicit actor foot', bounded=False)
        center, _, fit = self._geometry(selected, foot)
        row = self.frames[selected]; _, _, width, height = row['source_pixel_rect']
        source = row['anchors'][name]
        direction = -1 if self.flip_horizontal else 1
        return (center[0]+direction*(source[0]-.5)*width*fit/self.viewport[0],
                center[1]+(source[1]-.5)*height*fit/self.viewport[1])

    def foot_for_anchor(self, pose, target, name='hand'):
        """Place this pose's real anchor on an explicit scene contact point."""
        target = _point(target, 'target contact')
        offset = self.anchor(name, pose=pose, foot=(0,0))
        return target[0]-offset[0], target[1]-offset[1]

    def follow_path(self, name, start, end, *, offset=(0,0)):
        """Return exact integer-frame anchor samples, including pose cuts.

        The last sample is end-1. It can be held through a subsequent window;
        callers should use ordinary moves for an object whose native transfer
        position already overrides image-layer keyframes. No business action
        or binding is emitted here.
        """
        self._window(start, end)
        offset = _point(offset, 'held-object offset', bounded=False)
        points = []
        for frame in range(start, end):
            x,y = self.anchor(name, frame)
            points.append(dict(frame=frame,x=x+offset[0],y=y+offset[1]))
        return points

    def layer(self, *, start_frame=0, end_frame=None):
        """Return one native image layer for the complete explicit active window.

        Sparse linear keys retain every discrete source-frame geometry exactly;
        pose cuts have adjacent old/new keys rather than interpolating a scale
        change over a long hold. No StoryActions or causal evidence are added.
        Hidden branches can select a subwindow; its sequence and keys are
        rebuilt on that window rather than hiding out-of-range source rows.
        """
        end_frame = self.duration if end_frame is None else end_frame
        self._window(start_frame, end_frame)
        windows, keys = [], []
        for frame in range(start_frame, end_frame):
            pose = self.pose_at(frame); row = self.frames[pose]
            rect = row['source_rect']
            if windows and windows[-1]['sourceRect'] == rect:
                windows[-1]['endFrame'] = frame+1
            else:
                windows.append(dict(startFrame=frame,endFrame=frame+1,sourceRect=deepcopy(rect)))
            center, scale, fit = self._geometry(pose, self.foot_at(frame))
            _need(all(0 <= v <= 1 for v in center), 'the grounded actor layer center leaves the scene')
            _,_,width,height = row['source_pixel_rect']
            bounds = row.get('visible_pixel_bounds',(0,0,width,height))
            left_pixel, right_pixel = ((width-bounds[2],width-bounds[0]) if self.flip_horizontal
                                      else (bounds[0],bounds[2]))
            left = center[0]+(left_pixel-width/2)*fit/self.viewport[0]
            right = center[0]+(right_pixel-width/2)*fit/self.viewport[0]
            top = center[1]+(bounds[1]-height/2)*fit/self.viewport[1]
            bottom = center[1]+(bounds[3]-height/2)*fit/self.viewport[1]
            _need(-1e-10 <= left <= right <= 1+1e-10 and -1e-10 <= top <= bottom <= 1+1e-10,
                  'the actual grounded actor crop leaves the scene')
            key = dict(id=self.subject_id+'/pose-key/'+str(frame), frame=frame, x=center[0],y=center[1],scale=scale)
            if len(keys) >= 2:
                a,b = keys[-2:]
                ratio = (b['frame']-a['frame'])/(frame-a['frame'])
                if all(abs(b[field]-(a[field]+(key[field]-a[field])*ratio)) <= 1e-12 for field in ('x','y','scale')):
                    keys.pop()
            keys.append(key)
        _need(len(windows) <= 512, 'the actual image sequence exceeds the native 512-window limit')
        _need(len(keys) <= 256, 'the grounded actor exceeds the finite 256-keyframe author budget')
        first = keys[0]
        result = dict(id=self.subject_id, kind='图片', text='', assetID=self.asset_id,
            x=first['x'], y=first['y'], width=self.box[0], height=self.box[1], color='FFFFFF',
            opacity=1, startFrame=start_frame, endFrame=end_frame, locked=False, keyframes=keys)
        if self.flip_horizontal:
            result['imageFlipHorizontal'] = True
        if len(windows) == 1:
            result['sourceRect'] = windows[0]['sourceRect']
        else:
            result['imageSequence'] = dict(version=1,frames=windows)
        return result
