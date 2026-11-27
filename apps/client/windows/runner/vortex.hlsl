cbuffer Frame : register(b0) {
  float2 canvas; float2 origin;
  float2 size; float2 sink;
  float2 axis; float spin; float openness;
  float2 texel; float reduced; float density;
  float2 intakeInward; float cornerRadius; float padding;
};
Texture2D paper : register(t0);
SamplerState linearClamp : register(s0);
static const float pi = 3.14159265;

struct Sheet {
  float4 clip : SV_Position;
  float2 uv : TEXCOORD0;
  float3 surface : TEXCOORD1;
  float3 optical : TEXCOORD2;
};
float4 screenClip(float3 p) {
  return float4(p.xy / canvas * float2(2,-2) + float2(-1,1),
                saturate(.5 - p.z / (2.*length(size))), 1);
}
Sheet surfaceAt(float2 uv) {
  Sheet o;
  float2 start = origin + uv*size;
  float2 side = float2(-axis.y,axis.x);
  float span = max(1.,dot(abs(axis),size));
  float2 center = origin+.5*size;
  float2 initialEye = center - axis*min(span*.23,length(center-sink)*.48);
  float2 delta = start-initialEye;
  float along = dot(delta,axis), across = dot(delta,side);
  float fromFar = saturate(.5-dot((uv-.5)*size,axis)/span);
  float t = 1.-openness;
  float eased = t*t*(3.-2.*t);
  // An internal launch point keeps the original unfurl. At the taskbar the
  // contact point pulls on the glass itself: the rest doesn't travel with
  // a shared pivot before the pull has reached it.
  float2 contact = saturate((sink-origin)/size);
  float2 relative = (sink-center)/(.5*size);
  float dock = smoothstep(.78,1.,max(abs(relative.x),abs(relative.y)));
  float2 offset = (uv-contact)*size;
  float order = saturate(length(offset)/max(1.,length(max(contact,1.-contact)*size)));
  float acrossWindow = dot(offset,side)/max(1.,dot(abs(side),size));
  order = saturate(order + .32*spin*acrossWindow*order*(1.-order));
  float pickup = .215*order, arrival = .685+.315*order;
  float local = saturate((t-pickup)/(arrival-pickup));
  float localCurl = local*local*(3.-2.*local);
  float curl = lerp(saturate(eased + .97*eased*(1.-eased)*(2.*fromFar-1.)),
                    localCurl,dock);
  float life = sin(pi*curl);
  float reach = pow(max(0.,1.-curl),1.13);
  // Leave width in the trailing face. Its near and far ends can stretch
  // apart and show a fold before the hem rolls over.
  float width = pow(max(0.,1.-curl),lerp(1.48,1.13,dock))*(1.-lerp(.24,.14,dock)*life);
  float roll = spin*(3.9*curl*curl + .42*fromFar*life);
  float radial = along*reach;
  float ribbon = across*width*cos(roll);
  float height = across*width*sin(roll);
  // A turning centre line and a rotating cross section create a continuous
  // spiral, rather than a rigid window rotating around its centre.
  float turn = spin*(5.45*curl*curl + .13*life*(fromFar-.5));
  float sn, cs; sincos(turn,sn,cs);
  // A parcel starts travelling while its roll is still forming. Adjacent
  // parcels take differently bowed arcs and only share the final anchor.
  float glide = lerp(smoothstep(.10,.998,t),localCurl,dock);
  float bend = .075*sin(pi*glide);
  float release = 1.-.76*smoothstep(.45,.90,glide);
  float sweep = (.29+.16*order-.11*spin*acrossWindow)*sin(2.*pi*glide)*sin(pi*glide)*release
                + .085*sin(pi*glide);
  float2 eye = lerp(initialEye,sink,glide)+side*
      (spin*min(size.x,size.y)*lerp(bend,sweep,dock));
  float2 pos = eye + axis*(radial*(.33+.67*cs)-ribbon*sn*.58+height*.21)
                   + side*(radial*sn*.84+ribbon*cs);
  // A fold arriving at the bezel continues to turn tangentially, not behind
  // the monitor. Compress only the part of its normal travel that would
  // exhaust its clearance. The join has unit slope; no flat clipped hem.
  float clearance = max(0.,dot(start-sink,intakeInward))*(1.-glide);
  float knee = .72*clearance;
  float normalDist = dot(pos-sink,intakeInward);
  if (knee>0. && normalDist<knee) {
    float supported = knee*knee/(2.*knee-normalDist);
    pos += intakeInward*(dock*(supported-normalDist));
  }
  float settle = .014*sin(pi*saturate(t/.135))*(1.-smoothstep(0.,.135,t));
  pos += (start-center)*settle*(1.-dock);
  o.surface = float3(lerp(pos,start,reduced),height*(1.-reduced));
  o.clip = screenClip(o.surface);
  o.uv = uv;
  o.optical = float3(curl,roll,lerp(smoothstep(.008,.19,openness),
                                    1.-smoothstep(.90,.999,local),dock));
  return o;
}
Sheet SheetVS(uint vertex : SV_VertexID) {
  // Indices address the 97 by 65 normalized grid.
  return surfaceAt(float2(vertex%97,vertex/97)/float2(96,64));
}
float4 SheetPS(Sheet i, bool front : SV_IsFrontFace) : SV_Target {
  float curl = i.optical.x;
  float radius = lerp(cornerRadius, min(9.*density,min(size.x,size.y)*.04),
                      (1.-reduced)*smoothstep(0.,.12,curl));
  float2 q = abs((i.uv-.5)*size)-.5*size+radius;
  float sdf = min(max(q.x,q.y),0.)+length(max(q,0.))-radius;
  float inside = -sdf/max(.001,fwidth(sdf));
  if (reduced > .5 || openness >= 1.) {
    float alpha = openness * (radius > 0. ? saturate(inside+.5) : 1.);
    return float4(paper.Sample(linearClamp,i.uv).rgb*alpha,alpha);
  }
  float roll = i.optical.y;
  float alive = sin(pi*curl);
  float2 uv = i.uv;
  float3 dx = ddx(i.surface), dy = ddy(i.surface);
  float3 n = normalize(cross(dx,dy));
  float grazing = saturate(1.-abs(n.z));
  // Distance to a softened screen-space silhouette, in rendered pixels.
  float coverage = saturate(inside+.12);
  float rim = exp2(-.64*abs(inside-1.));
  float fold = grazing*grazing;
  float light = alive*saturate(.12+1.18*fold+.80*rim);
  float2 refractDir = float2(n.x + .28*sin(roll),n.y - .13*cos(roll));
  float2 bend = refractDir * (alive*(1.4+6.8*fold))*density*texel;
  float2 dispersion = (.3+1.8*light)*alive*density*texel*refractDir;
  float3 content;
  content.r = paper.Sample(linearClamp,uv+bend+dispersion).r;
  content.g = paper.Sample(linearClamp,uv+bend).g;
  content.b = paper.Sample(linearClamp,uv+bend-dispersion).b;
  float pearl = .5+.5*sin(roll*1.35+uv.x*3.7+uv.y*2.8);
  float3 ice = lerp(float3(.48,.83,1.),float3(.83,.68,1.),pearl);
  float silken = pow(saturate(dot(n,float3(-.31,-.49,.815))),12.);
  float back = front ? 0. : 1.;
  float phase = roll*3.1 + uv.x*1.15 + uv.y*.42;
  float crest = pow(saturate(.5+.5*cos(phase-1.55)),12.);
  float shade = pow(saturate(.5+.5*cos(phase-.74)),5.);
  float3 rgb = content*(1.-alive*(.13*shade+.10*back));
  rgb = lerp(rgb,ice,alive*(.065+.40*fold+.18*back+.13*crest));
  rgb = lerp(rgb,lerp(ice,1.,.56),saturate(light*.56+alive*(silken*.20+crest*.24)));
  rgb += alive*rim*.095;
  float alpha = coverage*(1.-alive*(.16+.20*fold))*i.optical.z;
  return float4(saturate(rgb)*alpha,alpha);
}

// A handful of brief glints peel from the two moving hems. Their positions
// use the very same surface function as the snapshot, including in reverse.
struct Mote { float4 clip : SV_Position; float2 p : TEXCOORD0; float2 light : TEXCOORD1; };
Mote GlintVS(uint vertex : SV_VertexID, uint id : SV_InstanceID) {
  float seed = frac(float(id)*.618034+.23);
  float age = saturate(((1.-openness)-.11-seed*.43)/.35);
  float2 uv = (id%2==0) ? float2(.08+.84*seed,1.) : float2(0.,.12+.8*seed);
  Sheet a = surfaceAt(uv);
  float2 normal2 = normalize(a.surface.xy - surfaceAt(lerp(uv,float2(.5,.5),.06)).surface.xy + .001);
  float2 center = a.surface.xy + normal2*(2.+age*(6.+seed*12.))*density;
  // Triangle strip: TL, TR, BL, BR.
  float2 p = float2((vertex & 1) ? 1. : -1.,(vertex>=2) ? 1. : -1.);
  Mote m;
  m.clip = screenClip(float3(center+p*(2.1+2.*seed)*density,0));
  m.p=p; m.light=float2(sin(pi*age)*.74*(1.-reduced),seed); return m;
}
float4 GlintPS(Mote m) : SV_Target {
  float r = dot(m.p,m.p);
  float a = (exp2(-4.3*r)*.48+exp2(-19.*r)*.52)*m.light.x;
  float3 color = lerp(float3(.67,.91,1.),float3(.95,.86,1.),m.light.y);
  return float4(color*a,a);
}
