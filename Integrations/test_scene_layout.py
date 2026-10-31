"""Semantic connections and profile geometry; no media or economic execution."""
from copy import deepcopy
import unittest
from scene_layout import SceneLayout, SceneLayoutError, Projection, present, transform, visible_bounds, sample_path, access_network


def layout():
    points={'orchard':dict(x=.2,y=.8),'junction':dict(x=.3,y=.5),'warehouse':dict(x=.6,y=.3)}
    links={key:dict(**{'from':a,'to':b},points=[points[a],points[b]],width=.08,group=key)
           for key,a,b in (('access','orchard','junction'),('shared','junction','warehouse'))}
    return dict(version=1,places=points,links=links,
                routes={'fruit':dict(**{'from':'orchard','to':'warehouse'},links=['access','shared'])})


def staged_scene():
    """Literal geometry only; these are not imported or rendered observations."""
    return dict(layers=[
        dict(id='courier',x=.25,y=.6,width=.12,height=.2,opacity=1,
             keyframes=[dict(frame=0,x=.2,y=.5,scale=1.1),dict(frame=20,x=.65,y=.65,scale=1.4)],
             sourceRect=dict(x=.2,y=.3,width=.4,height=.5),imageFlipHorizontal=True),
        dict(id='road',x=.5,y=.5,width=.5,height=.5,opacity=1,keyframes=[],
             texturedPath=dict(version=1,paths=[dict(width=.07,points=[
                 dict(x=.15,y=.3),dict(x=.55,y=.18),dict(x=.82,y=.4),dict(x=.4,y=.85)])])),
        dict(id='unused-pool',x=.01,y=.01,width=.01,height=.01,opacity=0,keyframes=[])],
        storyActions=[dict(id='delivery',kind='transfer',subjectID='courier',quantity=11,
                           startFrame=0,endFrame=30,
                           **{'from':dict(x=.2,y=.5),'to':dict(x=.93,y=.4)},
                           waypoints=[dict(x=.4,y=.7)])],
        storyCausality=dict(source='literal-source-only',amount=11),
        voice=dict(assetID='literal-take',durationFrames=30),captions=[dict(text='literal-caption')])


class SceneLayoutTests(unittest.TestCase):
    def test_network_builder_accepts_different_cast_size_and_connects_every_declared_need(self):
        carriers=('orchard','bakery','dairy')
        network=access_network(doors={'depot':dict(x=.2,y=.8)},
            loading_bays={c:dict(x=.1+i*.1,y=.8) for i,c in enumerate(carriers)},
            markets={c:dict(x=.2+i*.1,y=.3) for i,c in enumerate(carriers)},
            door_for={c:'depot' for c in carriers},
            trunk=[dict(x=.3,y=.7),dict(x=.3,y=.4)],width=.08)
        for carrier in carriers:
            self.assertTrue(network.reachable('depot','market-'+carrier))
            self.assertFalse(network.reachable('depot','market-'+carrier,closed_groups=['road-1']))
            self.assertEqual(network.route('haul-'+carrier)[0],network.places['load-'+carrier])

    def test_arbitrary_place_names_have_real_connected_routes_and_a_shared_cut(self):
        plan=SceneLayout(layout())
        self.assertTrue(plan.reachable('orchard','warehouse'))
        self.assertFalse(plan.reachable('orchard','warehouse',closed_groups=['shared']))
        self.assertEqual(plan.route('fruit'),[plan.places[k] for k in ('orchard','junction','warehouse')])
        bad=layout();bad['routes']['fruit']['links']=['shared','access']
        with self.assertRaises(SceneLayoutError):SceneLayout(bad)
        bad=layout();bad['links']['access']['points'][0]=dict(x=.1,y=.8)
        with self.assertRaises(SceneLayoutError):SceneLayout(bad)

    def test_motion_is_arc_length_continuous_exact_at_ends_and_still_transfers_remain_still(self):
        points=[dict(x=0,y=0),dict(x=.2,y=0),dict(x=.2,y=.6)]
        self.assertEqual(sample_path(points,0),points[0]);self.assertEqual(sample_path(points,1),points[-1])
        mid=sample_path(points,.5)
        self.assertAlmostEqual(mid['x'],.2);self.assertAlmostEqual(mid['y'],.2)
        self.assertEqual(sample_path([points[0],points[0]],.5),points[0])

    def test_profile_maps_layer_action_waypoints_and_road_width_without_touching_sources_or_causes(self):
        scene=dict(layers=[dict(id='person',x=.2,y=.6,width=.1,height=.2,opacity=1,keyframes=[],sourceRect=dict(x=.2,y=.3,width=.4,height=.5)),
                           dict(id='road',x=.5,y=.5,width=.5,height=.5,opacity=1,keyframes=[],
                                texturedPath=dict(version=1,paths=[dict(points=[dict(x=.2,y=.8),dict(x=.3,y=.4)],width=.08)])),
                           dict(id='unused-pool',x=.001,y=.001,width=.01,height=.01,opacity=0,keyframes=[])],
                   storyActions=[dict(kind='move',subjectID='person',startFrame=0,endFrame=10,
                                      **{'from':dict(x=.2,y=.6),'to':dict(x=.4,y=.5)},waypoints=[dict(x=.3,y=.7)])],
                   storyCausality=dict(id='unchanged-original-source'),voice=dict(hash='unchanged'))
        original=deepcopy(scene);projected=present(scene,'plain');host=present(scene,'presenter')
        self.assertEqual(scene,original)
        left,top,right,bottom=visible_bounds(projected)
        self.assertAlmostEqual((left+right)/2,.5)
        self.assertGreaterEqual(top,.21-1e-12);self.assertLessEqual(bottom,.89+1e-12)
        self.assertLessEqual(visible_bounds(host)[2],.62+1e-12)
        for key in ('storyCausality','voice'):self.assertEqual(projected[key],scene[key])
        self.assertEqual(projected['layers'][0]['sourceRect'],scene['layers'][0]['sourceRect'])
        restored=transform(projected,Projection(**projected['layout_projection']).inverse())
        for actual,expected in zip(restored['storyActions'][0]['waypoints'],scene['storyActions'][0]['waypoints']):
            for key in ('x','y'):self.assertAlmostEqual(actual[key],expected[key])
        self.assertAlmostEqual(restored['layers'][1]['texturedPath']['paths'][0]['width'],.08)
        self.assertAlmostEqual(visible_bounds(present(host,'plain'))[0],left)

    def test_transparent_logical_subject_keeps_legal_size_and_projects_position_reversibly(self):
        scene=dict(layers=[dict(id='pool-any-name',x=.4,y=.6,width=.01,height=.01,
                               opacity=0,keyframes=[])],storyActions=[])
        original=deepcopy(scene);projection=Projection(.5,.1,.15)
        projected=transform(scene,projection);pool=projected['layers'][0]
        self.assertEqual(scene,original)
        self.assertEqual((pool['width'],pool['height']),(.01,.01))
        self.assertAlmostEqual(pool['x'],.3);self.assertAlmostEqual(pool['y'],.45)
        restored=transform(projected,projection.inverse())['layers'][0]
        self.assertAlmostEqual(restored['x'],.4);self.assertAlmostEqual(restored['y'],.6)
        self.assertEqual((restored['width'],restored['height']),(.01,.01))

    def test_visible_small_layer_rejects_before_native_with_its_actual_identity(self):
        scene=dict(layers=[dict(id='visible-small-coin',x=.4,y=.6,width=.015,height=.02,
                               opacity=1,keyframes=[])],storyActions=[])
        original=deepcopy(scene)
        with self.assertRaisesRegex(SceneLayoutError,'visible-small-coin.*Native .01..1'):
            transform(scene,Projection(.5,0,0))
        self.assertEqual(scene,original)
        # Transparent subjects are not exempt from the original legal bounds.
        scene['layers'][0].update(id='invalid-logical-box',opacity=0,width=.009)
        with self.assertRaisesRegex(SceneLayoutError,'invalid-logical-box'):
            transform(scene,Projection(.5,0,0))

    def test_visible_enlargement_cannot_exceed_native_maximum_size(self):
        scene=dict(layers=[dict(id='visible-large-artwork',x=.4,y=.6,width=.6,height=.3,
                               opacity=1,keyframes=[])],storyActions=[])
        with self.assertRaisesRegex(SceneLayoutError,'visible-large-artwork.*Native .01..1'):
            transform(scene,Projection(2,0,0))

    def test_road_bounds_follow_actual_viewport_and_all_authored_polyline_points(self):
        scene=dict(layers=[dict(id='road',opacity=1,texturedPath=dict(version=1,paths=[
            dict(width=.07,points=[dict(x=.15,y=.3),dict(x=.55,y=.18),
                                   dict(x=.82,y=.4),dict(x=.4,y=.85)])]))],storyActions=[])
        half=.07/2
        landscape=(.15-half,.18-half*16/9,.82+half,.85+half*16/9)
        portrait=(.15-half,.18-half*9/16,.82+half,.85+half*9/16)
        self.assertEqual(visible_bounds(scene),landscape)
        self.assertEqual(visible_bounds(scene,viewport=(1280,720)),landscape)
        self.assertEqual(visible_bounds(scene,viewport=(1920,1080)),landscape)
        self.assertEqual(visible_bounds(scene,viewport=(720,1280)),portrait)
        self.assertEqual(visible_bounds(scene,viewport=(1080,1920)),portrait)
        self.assertGreater(portrait[1],landscape[1])
        self.assertLess(portrait[3],landscape[3])

    def test_omitted_viewport_preserves_exact_default_profile_projection(self):
        scene=staged_scene();original=deepcopy(scene)
        for mode in ('plain','presenter'):
            expected=present(scene,mode)
            self.assertEqual(present(scene,mode,viewport=(1280,720)),expected)
            self.assertEqual(present(scene,mode,viewport=(1920,1080)),expected)
            self.assertEqual(present(scene,mode,viewport=[1280,720],target_bounds=None),expected)
        self.assertEqual(scene,original)

    def test_portrait_explicit_story_box_fits_roads_poses_and_action_geometry_together(self):
        scene=staged_scene();original=deepcopy(scene);viewport=(720,1280)
        target=(.06,.06,.94,.42)
        result=present(scene,'presenter',viewport=viewport,target_bounds=target)
        left,top,right,bottom=visible_bounds(result,viewport=viewport)
        for actual,edge in ((left,target[0]),(top,target[1])):self.assertGreaterEqual(actual,edge-1e-12)
        for actual,edge in ((right,target[2]),(bottom,target[3])):self.assertLessEqual(actual,edge+1e-12)
        self.assertAlmostEqual((left+right)/2,(target[0]+target[2])/2)
        self.assertAlmostEqual((top+bottom)/2,(target[1]+target[3])/2)
        self.assertEqual(scene,original)
        for key in ('voice','captions','storyCausality'):self.assertEqual(result[key],scene[key])
        for old,new in zip(scene['storyActions'],result['storyActions']):
            self.assertEqual({k:v for k,v in old.items() if k not in ('from','to','waypoints')},
                             {k:v for k,v in new.items() if k not in ('from','to','waypoints')})
        self.assertEqual(result['layers'][0]['sourceRect'],scene['layers'][0]['sourceRect'])
        self.assertTrue(result['layers'][0]['imageFlipHorizontal'])
        self.assertEqual(result['layers'][-1]['width'],.01)
        self.assertEqual(result['layers'][-1]['height'],.01)
        self.assertNotIn('viewport',result)
        self.assertNotIn('target_bounds',result)
        projection=Projection(**result['layout_projection'])
        self.assertEqual(result['layers'][0]['keyframes'][1]['scale'],1.4)
        self.assertEqual(result['storyActions'][0]['waypoints'],
                         [projection.point(p) for p in scene['storyActions'][0]['waypoints']])

    def test_repeated_cross_viewport_projection_does_not_accumulate_geometry_drift(self):
        scene=staged_scene();result=deepcopy(scene)
        for _ in range(100):
            result=present(result,'presenter',viewport=(720,1280),target_bounds=(.06,.06,.94,.42))
            result=present(result,'plain',viewport=(1280,720))
        restored=transform(result,Projection(**result['layout_projection']).inverse())
        restored.pop('layout_projection');restored.pop('layout_profile')
        def compare(actual,expected):
            if isinstance(expected,dict):
                self.assertEqual(set(actual),set(expected))
                for key in expected:compare(actual[key],expected[key])
            elif isinstance(expected,list):
                self.assertEqual(len(actual),len(expected))
                for a,b in zip(actual,expected):compare(a,b)
            elif type(expected) is float:self.assertAlmostEqual(actual,expected,places=12)
            else:self.assertEqual(actual,expected)
        compare(restored,scene)
        expected=present(scene,'plain')
        self.assertAlmostEqual(result['layout_projection']['scale'],expected['layout_projection']['scale'],places=12)

    def test_invalid_actual_viewport_or_target_bounds_reject_without_mutation(self):
        scene=staged_scene();original=deepcopy(scene)
        for viewport in (None,(0,720),(True,720),(720.0,1280),(720,16385),(720,),('720',1280)):
            with self.subTest(viewport=viewport),self.assertRaises(SceneLayoutError):
                present(scene,'plain',viewport=viewport)
            with self.assertRaises(SceneLayoutError):visible_bounds(scene,viewport=viewport)
        for bounds in ((.1,.1,.1,.8),(.5,.1,.4,.8),(-.1,.1,.9,.8),(.1,.1,1.1,.8),
                       (.1,.1,.9,float('nan')),(.1,.1,.9,float('inf')),
                       (.1,True,.9,1),(.1,.1,.9),'portrait'):
            with self.subTest(bounds=bounds),self.assertRaises(SceneLayoutError):
                present(scene,'presenter',viewport=(720,1280),target_bounds=bounds)
        self.assertEqual(scene,original)


if __name__=='__main__':unittest.main()
