"""Semantic access/transport geometry before raster rendering.

The caller supplies places, connections and routes from story content. This
module never sees a cache inventory, invents a financial event, or generates
artwork. A presentation profile fits the same world into a visible viewport.
"""
from copy import deepcopy
from dataclasses import dataclass
import hashlib
import json
import math


class SceneLayoutError(ValueError):pass


def need(ok,message):
    if not ok:raise SceneLayoutError(message)


def point(value):
    need(isinstance(value,dict) and set(value)=={'x','y'} and
         all(type(value[k]) in (int,float) and math.isfinite(value[k]) and 0<=value[k]<=1
             for k in ('x','y')),'A scene point must use finite normalized stage coordinates')
    return value


def sample_path(points,progress):
    """Match the native normalized-stage arc-length contract, including ends."""
    need(len(points)>=2,'A route needs its actual start and destination')
    distances=[math.hypot(b['x']-a['x'],b['y']-a['y']) for a,b in zip(points,points[1:])]
    total=sum(distances)
    if total==0:return deepcopy(points[-1])  # Existing held transfers/reset cuts remain still.
    wanted=min(1,max(0,progress))*total
    for a,b,length in zip(points,points[1:],distances):
        if wanted<=length and length>0:
            t=wanted/length;return {k:a[k]+(b[k]-a[k])*t for k in ('x','y')}
        wanted-=length
    return deepcopy(points[-1])


def offset_path(points,delta):return [{k:p[k]+delta[k] for k in ('x','y')} for p in points]


class SceneLayout:
    def __init__(self,spec):
        self.spec=deepcopy(spec)
        need(spec.get('version')==1,'Unsupported semantic scene layout')
        self.places=spec['places'];self.links=spec['links'];self.routes=spec['routes']
        need(1<=len(self.places)<=64 and 1<=len(self.links)<=128 and len(self.routes)<=64,
             'Finite places, connections and routes required')
        for place in self.places.values():point(place)
        for link in self.links.values():
            need(link['from'] in self.places and link['to'] in self.places and link['from']!=link['to'],
                 'A road must connect two declared places')
            need(0<link['width']<=.25 and math.isfinite(link['width']),'Finite visible road width required')
            need(2<=len(link['points'])<=64 and link['points'][0]==self.places[link['from']]
                 and link['points'][-1]==self.places[link['to']], 'Road endpoints must meet actual place anchors')
            for p in link['points']:point(p)
        for identity in self.routes:self.route(identity)

    @property
    def fingerprint(self):
        return hashlib.sha256(json.dumps(self.spec,sort_keys=True,separators=(',',':'),allow_nan=False).encode()).hexdigest()

    def reachable(self,start,end,*,closed_groups=()):
        need(start in self.places and end in self.places,'Unknown access endpoint')
        visited={start};pending=[start]
        while pending:
            at=pending.pop()
            for link in self.links.values():
                if link['group'] in closed_groups:continue
                other=link['to'] if link['from']==at else link['from'] if link['to']==at else None
                if other is not None and other not in visited:visited.add(other);pending.append(other)
        return end in visited

    def route(self,identity):
        route=self.routes[identity];at=route['from'];points=[deepcopy(self.places[at])]
        for key in route['links']:
            need(key in self.links,'A transport route references an unknown road')
            link=self.links[key]
            if link['from']==at:part=link['points'];at=link['to']
            else:
                need(link['to']==at,'A transport route has a disconnected road')
                part=list(reversed(link['points']));at=link['from']
            points.extend(deepcopy(part[1:]))
        need(at==route['to'],'Transport must reach its declared unload destination')
        return points

    def textured_paths(self,group):
        rows=[dict(points=deepcopy(r['points']),width=r['width']) for r in self.links.values() if r['group']==group]
        need(bool(rows),'A visible road group cannot be empty')
        return dict(version=1,paths=rows)


def access_network(*,doors,loading_bays,markets,door_for,trunk,width):
    """Construct a shared fishbone network from the story's access needs.

    Keys may name any people, buildings or depots. The source and destination
    anchors are explicit content/layout inputs, never a list of cached assets.
    """
    need(set(loading_bays)==set(markets)==set(door_for) and bool(loading_bays),
         'Every declared carrier requires a door, loading bay and destination')
    need(2<=len(trunk)<=16 and len(loading_bays)<=16,'Finite shared road and carrier budget required')
    places={key:deepcopy(value) for key,value in doors.items()};links={};routes={}
    for i,p in enumerate(trunk):places['junction-'+str(i)]=deepcopy(p)
    def link(identity,a,b,group):
        links[identity]=dict(**{'from':a,'to':b},points=[deepcopy(places[a]),deepcopy(places[b])],width=width,group=group)
    main=[]
    for i in range(len(trunk)-1):
        key='main-'+str(i+1);main.append(key)
        link(key,'junction-'+str(i),'junction-'+str(i+1),'road-'+str(i+1))
    for carrier in loading_bays:
        need(door_for[carrier] in doors,'Carrier references an unknown actual access door')
        load,market='load-'+carrier,'market-'+carrier
        places[load]=deepcopy(loading_bays[carrier]);places[market]=deepcopy(markets[carrier])
        link('door-access-'+carrier,door_for[carrier],load,'approaches')
        link('load-access-'+carrier,load,'junction-0','approaches')
        link('market-access-'+carrier,'junction-'+str(len(trunk)-1),market,'approaches')
        routes['haul-'+carrier]=dict(**{'from':load,'to':market},
                                    links=['load-access-'+carrier,*main,'market-access-'+carrier])
    return SceneLayout(dict(version=1,places=places,links=links,routes=routes))


@dataclass(frozen=True)
class Projection:
    scale:float
    tx:float
    ty:float

    def point(self,value):return {k:getattr(self,'t'+k)+self.scale*value[k] for k in ('x','y')}
    def inverse(self):return Projection(1/self.scale,-self.tx/self.scale,-self.ty/self.scale)
    def to_dict(self):return dict(scale=self.scale,tx=self.tx,ty=self.ty)


PROFILES={'presenter':(.025,.17,.595,.72),'plain':(.06,.21,.88,.68)}


def visible_bounds(scene):
    """Conservative union through all authored poses; invisible pool excluded."""
    result=[]
    for layer in scene['layers']:
        if layer.get('opacity',1)<=0:continue
        path=layer.get('texturedPath')
        if path:
            for road in path['paths']:
                half=road['width']/2
                # Width is normalized by canvas width; landscape is 16:9.
                for p in road['points']:result.append((p['x']-half,p['y']-half*16/9,p['x']+half,p['y']+half*16/9))
            continue
        poses=[dict(x=layer['x'],y=layer['y'],scale=1)]+layer.get('keyframes',[])
        max_scale=max(p.get('scale',1) for p in poses)
        for action in scene['storyActions']:
            if action['subjectID']==layer['id'] and action['kind'] in ('move','transfer'):
                poses.extend([action['from'],*action.get('waypoints',[]),action['to']])
        w=layer['width']*max_scale/2;h=layer['height']*max_scale/2
        result.extend((p['x']-w,p['y']-h,p['x']+w,p['y']+h) for p in poses)
    need(bool(result),'A visible business stage is required')
    return (min(p[0] for p in result),min(p[1] for p in result),max(p[2] for p in result),max(p[3] for p in result))


def transform(scene,projection):
    result=deepcopy(scene)
    for layer in result['layers']:
        layer.update(projection.point(layer))
        layer['width']*=projection.scale;layer['height']*=projection.scale
        for key in layer.get('keyframes',[]):key.update(projection.point(key))
        for road in layer.get('texturedPath',{}).get('paths',[]):
            road['points']=[projection.point(p) for p in road['points']];road['width']*=projection.scale
    for action in result['storyActions']:
        for key in ('from','to'):
            if key in action:action[key]=projection.point(action[key])
        if 'waypoints' in action:action['waypoints']=[projection.point(p) for p in action['waypoints']]
    return result


def present(scene,mode):
    need(mode in PROFILES,'Unknown story presentation profile')
    canonical=deepcopy(scene)
    prior=canonical.pop('layout_projection',None)
    if prior:canonical=transform(canonical,Projection(**prior).inverse())
    left,top,right,bottom=visible_bounds(canonical);x,y,w,h=PROFILES[mode]
    scale=min(w/(right-left),h/(bottom-top))
    projection=Projection(scale,x+w/2-scale*(left+right)/2,y+h/2-scale*(top+bottom)/2)
    result=transform(canonical,projection);result['layout_projection']=projection.to_dict()
    result['layout_profile']=mode
    return result
