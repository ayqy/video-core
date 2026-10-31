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


if __name__=='__main__':unittest.main()
