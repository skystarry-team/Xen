(* SPDX-License-Identifier: Apache-2.0 AND SunPro *)
(* Portable arithmetic helpers are compiled through the ordinary checked IR.
   The pow algorithm below is adapted from OpenLibm src/e_pow.c (fdlibm).
   https://github.com/JuliaMath/openlibm/blob/master/src/e_pow.c
   Copyright (C) 2004 by Sun Microsystems, Inc. All rights reserved.
   Permission to use, copy, modify, and distribute this software is freely
   granted, provided that this notice is preserved.

   The remainder routine uses exact unsigned significand shift/subtraction,
   following the method in OpenLibm src/e_fmod.c.
   Copyright (C) 1993 by Sun Microsystems, Inc. All rights reserved.
   Developed at SunSoft, a Sun Microsystems, Inc. business.
   Permission to use, copy, modify, and distribute this software is freely
   granted, provided that this notice is preserved.

   Xen adaptation: 64-bit word operations, explicit checked conversions, native
   bit reinterpretation/sqrt/narrowing primitives, no dependence on C or an OS.
   F32 evaluates the binary64 algorithm and rounds once to binary32. *)
open Ast
open Semantic_ir

let private_name name = "$math$" ^ String.sub name 6 (String.length name-6)
let is_helper = String.starts_with ~prefix:"$math$"
let intrinsics = ["xmath_bits_u64",(F64,U64);"xmath_bits_f64",(U64,F64);
                  "xmath_narrow_f32",(F64,F32);"xmath_sqrt_f64",(F64,F64)]

let source = {|
fn xmath_entry(){}
fn xmath_high(x:F64)->Int{
 let h=i64(xmath_bits_u64(x)>>u64(32));
 if h>=2147483648{return h-4294967296;}return h;
}
fn xmath_low(x:F64)->Int{return i64(xmath_bits_u64(x)&u64(4294967295));}
fn xmath_set_high(x:F64,h:Int)->F64{
 let mut u=u64(0);if h<0{u=u64(h+4294967296);}else{u=u64(h);}
 return xmath_bits_f64((xmath_bits_u64(x)&u64(4294967295))|(u<<u64(32)));
}
fn xmath_trunc_low(x:F64)->F64{
 return xmath_bits_f64(xmath_bits_u64(x)&u64(18446744069414584320));
}
fn xmath_scale(x:F64,n:Int)->F64{
 if n>1023{return (x*xmath_bits_f64(u64(9214364837600034816)))*2.0;}
 if n< -1022{
  let factor=xmath_bits_f64(u64(n+1123)<<u64(52));
  return (x*factor)*7.88860905221011805412e-31;
 }
 return x*xmath_bits_f64(u64(n+1023)<<u64(52));
}
fn xmath_fmod64(x:F64,y:F64)->F64{
 let ux=xmath_bits_u64(x);let uy=xmath_bits_u64(y)&u64(9223372036854775807);
 let ax=ux&u64(9223372036854775807);let sign=ux&u64(9223372036854775808);
 if uy==u64(0)||ax>=u64(9218868437227405312)||uy>u64(9218868437227405312){return (x*y)/(x*y);}
 if ax<=uy{if ax==uy{return xmath_bits_f64(sign);}return x;}
 let mut ex=i64(ax>>u64(52))-1023;let mut ey=i64(uy>>u64(52))-1023;
 let mut mx=ax&u64(4503599627370495);let mut my=uy&u64(4503599627370495);
 if ex== -1023{ex= -1022;while mx<u64(4503599627370496){mx=mx<<u64(1);ex=ex-1;}}
 else{mx=mx|u64(4503599627370496);}
 if ey== -1023{ey= -1022;while my<u64(4503599627370496){my=my<<u64(1);ey=ey-1;}}
 else{my=my|u64(4503599627370496);}
 while ex>ey{
  if mx>=my{mx=mx-my;if mx==u64(0){return xmath_bits_f64(sign);}}
  mx=mx<<u64(1);ex=ex-1;
 }
 if mx>=my{mx=mx-my;}if mx==u64(0){return xmath_bits_f64(sign);}
 while mx<u64(4503599627370496){mx=mx<<u64(1);ey=ey-1;}
 let mut raw=u64(0);
 if ey>= -1022{raw=(u64(ey+1023)<<u64(52))|(mx-u64(4503599627370496));}
 else{raw=mx>>u64(-1022-ey);}
 return xmath_bits_f64(raw|sign);
}
fn xmath_fmod32(x:F32,y:F32)->F32{return xmath_narrow_f32(xmath_fmod64(f64(x),f64(y)));}
fn xmath_pow32(x:F32,y:F32)->F32{return xmath_narrow_f32(xmath_pow64(f64(x),f64(y)));}
fn xmath_pow64(x:F64,y:F64)->F64{
 let hx=xmath_high(x);let hy=xmath_high(y);let lx=xmath_low(x);let ly=xmath_low(y);
 let mut ix=hx&2147483647;let iy=hy&2147483647;
 if (iy|ly)==0{return 1.0;}
 if hx==1072693248&&lx==0{return 1.0;}
 if ix>2146435072||(ix==2146435072&&lx!=0)||iy>2146435072||(iy==2146435072&&ly!=0){return (x+0.0)+(y+0.0);}
 let mut yisint=0;let mut k=0;let mut j=0;let mut n=0;
 if hx<0{
  if iy>=1128267776{yisint=2;}
  else if iy>=1072693248{
   k=(iy>>20)-1023;
   if k>20{j=ly>>(52-k);if j<<(52-k)==ly{yisint=2-(j&1);}}
   else if ly==0{j=iy>>(20-k);if j<<(20-k)==iy{yisint=2-(j&1);}}
  }
 }
 if ly==0{
  if iy==2146435072{
   if ((ix-1072693248)|lx)==0{return 1.0;}
   if ix>=1072693248{if hy>=0{return y;}return 0.0;}
   if hy<0{return -y;}return 0.0;
  }
  if iy==1072693248{if hy<0{return 1.0/x;}return x;}
  if hy==1073741824{return x*x;}
  if hy==1074266112{return x*x*x;}
  if hy==1074790400{let u=x*x;return u*u;}
  if hy==1071644672&&hx>=0{return xmath_sqrt_f64(x);}
 }
 let mut ax=xmath_bits_f64(xmath_bits_u64(x)&u64(9223372036854775807));
 let mut z=0.0;
 if lx==0{
  if ix==2146435072||ix==0||ix==1072693248{
   z=ax;if hy<0{z=1.0/z;}
   if hx<0{if ((ix-1072693248)|yisint)==0{z=(z-z)/(z-z);}else if yisint==1{z= -z;}}
   return z;
  }
 }
 if hx<0&&yisint==0{return (x-x)/(x-x);}
 let mut sign=1.0;if hx<0&&yisint==1{sign= -1.0;}
 let mut t=0.0;let mut w=0.0;let mut u=0.0;let mut v=0.0;
 let mut t1=0.0;let mut t2=0.0;let mut r=0.0;let mut ph=0.0;let mut pl=0.0;
 if iy>1105199104{
  if iy>1139802112{
   if ix<=1072693247{if hy<0{return 1e300*1e300;}return 1e-300*1e-300;}
   if ix>=1072693248{if hy>0{return 1e300*1e300;}return 1e-300*1e-300;}
  }
  if ix<1072693247{if hy<0{return sign*1e300*1e300;}return sign*1e-300*1e-300;}
  if ix>1072693248{if hy>0{return sign*1e300*1e300;}return sign*1e-300*1e-300;}
  t=ax-1.0;w=(t*t)*(0.5-t*(0.3333333333333333333333-t*0.25));
  u=1.44269502162933349609*t;v=t*1.92596299112661746887e-08-w*1.44269504088896338700;
  t1=xmath_trunc_low(u+v);t2=v-(t1-u);
 }else{
  n=0;if ix<1048576{ax=ax*9007199254740992.0;n=n-53;ix=xmath_high(ax);}
  n=n+(ix>>20)-1023;j=ix&1048575;ix=j|1072693248;
  k=0;if j>235662{if j<767610{k=1;}else{n=n+1;ix=ix-1048576;}}
  ax=xmath_set_high(ax,ix);
  let mut bp=1.0;let mut dph=0.0;let mut dpl=0.0;
  if k==1{bp=1.5;dph=5.84962487220764160156e-01;dpl=1.35003920212974897128e-08;}
  u=ax-bp;v=1.0/(ax+bp);let ss=u*v;let sh=xmath_trunc_low(ss);
  let mut th=xmath_set_high(0.0,((ix>>1)|536870912)+524288+(k<<18));
  let mut tl=ax-(th-bp);let sl=v*((u-sh*th)-sh*tl);let mut s2=ss*ss;
  r=s2*s2*(5.99999999999994648725e-01+s2*(4.28571428578550184252e-01+s2*(3.33333329818377432918e-01+s2*(2.72728123808534006489e-01+s2*(2.30660745775561754067e-01+s2*2.06975017800338417784e-01)))));
  r=r+sl*(sh+ss);s2=sh*sh;th=xmath_trunc_low(3.0+s2+r);tl=r-((th-3.0)-s2);
  u=sh*th;v=sl*th+tl*ss;ph=xmath_trunc_low(u+v);pl=v-(ph-u);
  let zh=9.61796700954437255859e-01*ph;
  let zl= -7.02846165095275826516e-09*ph+pl*9.61796693925975554329e-01+dpl;
  t=f64(n);t1=xmath_trunc_low(((zh+zl)+dph)+t);t2=zl-(((t1-t)-dph)-zh);
 }
 let y1=xmath_trunc_low(y);pl=(y-y1)*t1+y*t2;ph=y1*t1;z=pl+ph;
 j=xmath_high(z);let low=xmath_low(z);
 if j>=1083179008{
  if j!=1083179008||low!=0{return sign*1e300*1e300;}
  if pl+8.0085662595372944372e-17>z-ph{return sign*1e300*1e300;}
 }else if (j&2147483647)>=1083231232{
  if j!= -1064252416||low!=0{return sign*1e-300*1e-300;}
  if pl<=z-ph{return sign*1e-300*1e-300;}
 }
 let i=j&2147483647;k=(i>>20)-1023;n=0;
 if i>1071644672{
  n=j+(1048576>>(k+1));k=((n&2147483647)>>20)-1023;
  t=xmath_set_high(0.0,n&~(1048575>>k));
  n=((n&1048575)|1048576)>>(20-k);if j<0{n= -n;}ph=ph-t;
 }
 t=xmath_trunc_low(pl+ph);u=t*6.93147182464599609375e-01;
 v=(pl-(t-ph))*6.93147180559945286227e-01+t* -1.90465429995776804525e-09;
 z=u+v;w=v-(z-u);t=z*z;
 t1=z-t*(1.66666666666666019037e-01+t*( -2.77777777770155933842e-03+t*(6.61375632143793436117e-05+t*( -1.65339022054652515390e-06+t*4.13813679705723846039e-08))));
 r=(z*t1)/(t1-2.0)-(w+z*w);z=1.0-(r-z);
 j=xmath_high(z)+(n<<20);
 if (j>>20)<=0{z=xmath_scale(z,n);}else{z=xmath_set_high(z,j);}
 return sign*z;
}
|}

let operator_helper operator typ =
  "$math$"^(if operator="**"then "pow"else "fmod")^(if typ=F32 then "32"else "64")
let roots program =
  List.concat_map(fun(f:func)->Array.to_list f.blocks |> List.concat_map(fun(b:block)->
    List.filter_map(fun(op:operation)->match op.node with
      |Eval(v,Binary(("**"|"%"as operator),_,_))when Type_desc.is_float v.typ->Some(operator_helper operator v.typ)
      |_->None)b.operations))program.functions |> List.sort_uniq String.compare

let link program library =
  let helpers=List.filter(fun(f:func)->f.name<>"xmath_entry")library.functions in
  let names=List.map(fun(f:func)->f.name,private_name f.name)helpers in
  let rename name=Option.value ~default:name(List.assoc_opt name names)in
  let helpers=List.map(fun(f:func)->{f with name=rename f.name;blocks=Array.map(fun(b:block)->
    {b with operations=List.map(fun(op:operation)->match op.node with
      |Eval(v,Call(name,args))->{op with node=Eval(v,Call(rename name,args))}|_->op)b.operations})f.blocks})helpers in
  let reached=Hashtbl.create 16 in
  let rec visit name=if not(Hashtbl.mem reached name)then begin
    Hashtbl.add reached name();match List.find_opt(fun(f:func)->f.name=name)helpers with
    |None->()|Some f->Array.iter(fun(b:block)->List.iter(fun(op:operation)->match op.node with
      |Eval(_,Call(name,_))when is_helper name->visit name|_->())b.operations)f.blocks end in
  List.iter visit(roots program);
  let functions=List.map(fun(f:func)->{f with blocks=Array.map(fun(b:block)->
    {b with operations=List.map(fun(op:operation)->match op.node with
      |Eval(v,Binary(("**"|"%"as operator),a,b))when Type_desc.is_float v.typ->
          {op with node=Eval(v,Call(operator_helper operator v.typ,[a;b]))}|_->op)b.operations})f.blocks})program.functions in
  {program with functions=List.mapi(fun id(f:func)->{f with id})
    (functions@List.filter(fun(f:func)->Hashtbl.mem reached f.name)helpers)}
