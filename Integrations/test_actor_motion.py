"""Pure metadata/geometry rules; no image viewing, Core or media verification.

Literal atlases exercise different crop ratios and asymmetric foot anchors.
They do not assert that a real drawn hand or shoe was visually accepted.
"""
from copy import deepcopy
import unittest

from actor_motion import ActorMotionError, ActorTrack


def literal_frames():
    result = {}
    for index,(name,w,h,foot,hand) in enumerate([
            ('idle',200,400,(.5,.95),(.8,.4)),
            ('carry',400,200,(.5,.9),(.7,.5)),
            ('give',100,400,(.6,.9),(.9,.3)),
            ('walk_left',210,400,(.5,.94),(.72,.5)),
            ('walk_right',190,400,(.5,.96),(.74,.49))]):
        result[name] = dict(source_pixel_rect=[index*400,0,w,h],
            source_rect=dict(x=index*.1,y=0,width=.08,height=.5),
            anchors=dict(foot=foot,hand=hand,pocket=(.2,.6)))
    result['carry']['anchors']['receive'] = (.3,.6)
    return result


def make_track(**kwargs):
    return ActorTrack('literal-actor','literal-asset',kwargs.pop('frames',literal_frames()),
        duration=kwargs.pop('duration',30),viewport=kwargs.pop('viewport',(1000,500)),
        box=kwargs.pop('box',(.2,.6)),foot_drop=kwargs.pop('foot_drop',.18),
        initial_foot=kwargs.pop('initial_foot',(.3,.75)),**kwargs)


def projected_anchor(layer,row,name,frame,viewport=(1000,500)):
    """Independent source-crop image-fit calculation on the emitted layer IR."""
    keys=layer['keyframes'];current=keys[-1]
    for left,right in zip(keys,keys[1:]):
        if left['frame'] <= frame < right['frame']:
            mix=(frame-left['frame'])/(right['frame']-left['frame'])
            current={field:left[field]+(right[field]-left[field])*mix for field in ('x','y','scale')}
            break
    if frame <= keys[0]['frame']:current=keys[0]
    _,_,w,h=row['source_pixel_rect'];W,H=viewport
    fitted=min(layer['width']*current['scale']*W/w,layer['height']*current['scale']*H/h)
    anchor=row['anchors'][name]
    rendered_x=1-anchor[0] if layer.get('imageFlipHorizontal') else anchor[0]
    return (current['x']+(rendered_x-.5)*w*fitted/W,
            current['y']+(anchor[1]-.5)*h*fitted/H)


class ActorMotionRulesTests(unittest.TestCase):
    def assertPoint(self,actual,expected):
        self.assertAlmostEqual(actual[0],expected[0],places=10)
        self.assertAlmostEqual(actual[1],expected[1],places=10)

    def test_emitted_image_fit_keeps_the_same_foot_across_different_crop_ratios_and_offsets(self):
        track=make_track().pose(5,12,'carry').pose(12,20,'give')
        layer=track.layer()
        self.assertEqual([(r['startFrame'],r['endFrame']) for r in layer['imageSequence']['frames']],
                         [(0,5),(5,12),(12,20),(20,30)])
        for frame in range(30):
            row=track.frames[track.pose_at(frame)]
            self.assertPoint(projected_anchor(layer,row,'foot',frame),(.3,.75))
        # This is a measured consequence of the literal idle crop/image fit.
        self.assertPoint(projected_anchor(layer,track.frames['idle'],'hand',0),(.33,.53))
        self.assertPoint(track.anchor('hand',0),(.33,.53))

    def test_contact_stance_places_the_real_selected_pose_hand_or_receive_anchor_on_target(self):
        track=make_track()
        for pose,name,target in [('give','hand',(.55,.52)),('carry','receive',(.45,.61)),('idle','pocket',(.4,.57))]:
            foot=track.foot_for_anchor(pose,target,name)
            self.assertPoint(track.anchor(name,pose=pose,foot=foot),target)
            placed=make_track(initial_foot=foot).pose(0,30,pose).layer()
            self.assertPoint(projected_anchor(placed,track.frames[pose],name,10),target)

    def test_horizontal_flip_preserves_original_crops_and_grounding_and_mirrors_contact_paths(self):
        original=literal_frames();before=deepcopy(original)
        plain=make_track(frames=original).pose(5,12,'carry').pose(12,20,'give')
        flipped=make_track(frames=original,flip_horizontal=True).pose(5,12,'carry').pose(12,20,'give')
        for track in (plain,flipped):track.move(2,22,(.3,.75),(.6,.72))
        normal_layer,flipped_layer=plain.layer(),flipped.layer()
        self.assertNotIn('imageFlipHorizontal',normal_layer)
        self.assertIs(flipped_layer['imageFlipHorizontal'],True)
        self.assertEqual(original,before)
        self.assertEqual(normal_layer['imageSequence'],flipped_layer['imageSequence'])
        for frame in range(30):
            row=flipped.frames[flipped.pose_at(frame)]
            foot=flipped.foot_at(frame)
            self.assertPoint(projected_anchor(flipped_layer,row,'foot',frame),foot)
            for name in ('hand','pocket'):
                actual=projected_anchor(flipped_layer,row,name,frame)
                self.assertPoint(flipped.anchor(name,frame),actual)
                other=plain.anchor(name,frame)
                self.assertAlmostEqual(actual[0]+other[0],2*foot[0],places=10)
                self.assertAlmostEqual(actual[1],other[1],places=10)
        for point in flipped.follow_path('hand',6,18):
            frame=point['frame'];row=flipped.frames[flipped.pose_at(frame)]
            self.assertPoint((point['x'],point['y']),projected_anchor(flipped_layer,row,'hand',frame))
        target=(.55,.53)
        stance=flipped.foot_for_anchor('give',target)
        placed=make_track(flip_horizontal=True,initial_foot=stance).pose(0,30,'give').layer()
        self.assertPoint(projected_anchor(placed,original['give'],'hand',15),target)
        for bad in (0,1,'true',None):
            with self.subTest(flip=bad),self.assertRaises(ActorMotionError):make_track(flip_horizontal=bad)

    def test_actor_moves_with_actual_walk_crops_and_holds_the_destination_afterwards(self):
        track=make_track().walk(3,15,stride=3).move(3,15,(.3,.75),(.6,.75))
        layer=track.layer()
        self.assertEqual([track.pose_at(f) for f in (3,6,9,12)],['walk_left','walk_right','walk_left','walk_right'])
        for frame,expected in [(2,(.3,.75)),(3,(.3,.75)),(14,(.6,.75)),(15,(.6,.75)),(29,(.6,.75))]:
            self.assertPoint(track.foot_at(frame),expected)
            self.assertPoint(projected_anchor(layer,track.frames[track.pose_at(frame)],'foot',frame),expected)

    def test_held_item_path_tracks_pose_cuts_and_all_integer_route_samples_exactly(self):
        track=make_track().pose(4,10,'carry').pose(10,18,'give')
        track.move(2,22,(.3,.75),(.58,.71),waypoints=[(.4,.65)])
        path=track.follow_path('hand',2,22,offset=(.01,-.02));layer=track.layer()
        self.assertEqual([p['frame'] for p in path],list(range(2,22)))
        for row in path:
            actual=projected_anchor(layer,track.frames[track.pose_at(row['frame'])],'hand',row['frame'])
            self.assertPoint((row['x'],row['y']),(actual[0]+.01,actual[1]-.02))
        self.assertNotEqual((path[7]['x'],path[7]['y']),(path[8]['x'],path[8]['y']))

    def test_follow_path_is_plain_visual_data_for_unbound_moves_not_another_business_claim(self):
        track=make_track().pose(0,30,'carry')
        path=track.follow_path('receive',5,9)
        self.assertEqual(path[-1]['frame'],8)  # end-exclusive; never generates a duration+1 key.
        self.assertTrue(all(set(p)=={'frame','x','y'} for p in path))
        self.assertFalse({'storyActions','storyCausality','bindings','quantity','targetID'} & track.layer().keys())
        # The caller must put these points in ordinary move actions if an
        # existing native transfer holds its final position. A layer keyframe
        # alone cannot override that native final position (documented contract).

    def test_viewport_and_frame_rate_are_explicit_and_a_single_still_pose_needs_no_fake_sequence(self):
        for viewport in ((720,1280),(1920,1080)):
            track=make_track(viewport=viewport,fps=24,duration=17,box=(.4,.5),foot_drop=.12)
            layer=track.layer()
            self.assertEqual(track.fps,24);self.assertEqual(layer['endFrame'],17)
            self.assertNotIn('imageSequence',layer)
            self.assertIn('sourceRect',layer)
            self.assertPoint(projected_anchor(layer,track.frames['idle'],'foot',8,viewport),(.3,.75))

    def test_copy_by_value_preserves_original_manifest_and_layer_independence(self):
        frames=literal_frames();before=deepcopy(frames);track=make_track(frames=frames)
        track.pose(3,7,'carry');layer=track.layer()
        layer['imageSequence']['frames'][0]['sourceRect']['x']=.9
        self.assertEqual(frames,before)
        self.assertEqual(track.layer()['imageSequence']['frames'][0]['sourceRect']['x'],0)

    def test_active_layer_window_rebuilds_complete_keys_and_crop_intervals_and_rejects_bad_windows(self):
        track=make_track().pose(4,12,'carry').pose(12,20,'give')
        track.move(2,22,(.3,.75),(.6,.72))
        for start,end in ((0,16),(7,30),(6,10),(8,9)):
            with self.subTest(start=start,end=end):
                layer=track.layer(start_frame=start,end_frame=end)
                self.assertEqual((layer['startFrame'],layer['endFrame']),(start,end))
                self.assertEqual(layer['keyframes'][0]['frame'],start)
                self.assertEqual(layer['keyframes'][-1]['frame'],end-1)
                self.assertTrue(all(start <= k['frame'] < end for k in layer['keyframes']))
                if 'imageSequence' in layer:
                    windows=layer['imageSequence']['frames']
                    self.assertEqual(windows[0]['startFrame'],start)
                    self.assertEqual(windows[-1]['endFrame'],end)
                    self.assertTrue(all(a['endFrame']==b['startFrame'] for a,b in zip(windows,windows[1:])))
                for frame in range(start,end):
                    self.assertPoint(projected_anchor(layer,track.frames[track.pose_at(frame)],'foot',frame),track.foot_at(frame))
        for start,end in ((-1,5),(3,3),(0,31),(True,3)):
            with self.subTest(start=start,end=end),self.assertRaises(ActorMotionError):
                track.layer(start_frame=start,end_frame=end)

    def test_pose_sequence_below_512_still_rejects_more_than_256_grounding_keys(self):
        track=make_track(duration=390)
        for index in range(130):track.pose(index*3,index*3+3,'carry' if index%2 else 'give')
        with self.assertRaisesRegex(ActorMotionError,'256-keyframe'):
            track.layer()
        # A short active slice of that same valid pose schedule remains usable.
        layer=track.layer(start_frame=10,end_frame=35)
        self.assertLessEqual(len(layer['keyframes']),256)

    def test_pose_and_foot_motion_windows_cannot_overlap_or_teleport(self):
        track=make_track().pose(3,8,'carry')
        with self.assertRaisesRegex(ActorMotionError,'overlap'):track.pose(7,10,'give')
        with self.assertRaisesRegex(ActorMotionError,'overlap'):track.walk(2,12)
        track.move(3,8,(.3,.75),(.4,.75))
        with self.assertRaisesRegex(ActorMotionError,'nonoverlapping'):track.move(7,10,(.4,.75),(.5,.75))
        with self.assertRaisesRegex(ActorMotionError,'previous held foot'):track.move(10,15,(.3,.75),(.5,.75))
        track.move(10,15,(.4,.75),(.5,.75))
        self.assertPoint(track.foot_at(29),(.5,.75))

    def test_missing_pose_or_anchor_does_not_fabricate_a_performance(self):
        track=make_track()
        with self.assertRaisesRegex(ActorMotionError,'absent'):track.pose(3,8,'imaginary')
        with self.assertRaisesRegex(ActorMotionError,'no requested anchor'):track.anchor('receive',pose='idle')
        frames=literal_frames();del frames['walk_right']
        with self.assertRaisesRegex(ActorMotionError,'two actual walking poses'):make_track(frames=frames).walk(0,12)

    def test_invalid_crop_anchor_scale_and_scene_bounds_are_rejected(self):
        for mutation in ('crop','pixels','foot','anchor'):
            frames=literal_frames()
            if mutation=='crop':frames['idle']['source_rect']['width']=2
            if mutation=='pixels':frames['idle']['source_pixel_rect'][2]=0
            if mutation=='foot':frames['idle']['anchors']['foot']=(.5,.5)
            if mutation=='anchor':frames['idle']['anchors']['hand']=(float('nan'),.2)
            with self.subTest(mutation=mutation),self.assertRaises(ActorMotionError):make_track(frames=frames)
        with self.assertRaisesRegex(ActorMotionError,'scale range'):make_track(box=(.01,.01),foot_drop=.4)
        with self.assertRaisesRegex(ActorMotionError,'leaves the scene'):make_track(initial_foot=(.01,.75)).layer()
        for start,end in ((-1,5),(3,3),(0,31),(True,3)):
            with self.subTest(start=start,end=end),self.assertRaises(ActorMotionError):make_track().pose(start,end,'idle')


if __name__ == '__main__':
    unittest.main()
