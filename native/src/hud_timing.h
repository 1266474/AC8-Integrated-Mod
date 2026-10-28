#pragma once
#include <array>
#include <atomic>
#include <cstdint>
#include <algorithm>
#include <cmath>
#include <limits>
struct HudTiming {
 // Keep 0.25ms resolution through 256ms. A percentile in the overflow
 // bucket is bounded by the lifetime maximum instead of pretending to be 32ms.
 std::array<std::atomic<uint64_t>,1025> bins{};std::atomic<uint64_t> last{0},max_us{0},excluded{0},excluded_max_us{0};
 static void maximum(std::atomic<uint64_t>& value,uint64_t us){auto old=value.load(std::memory_order_relaxed);while(old<us&&!value.compare_exchange_weak(old,us,std::memory_order_relaxed)){};}
 static uint64_t microseconds(double ms){return uint64_t(std::min(ms*1000,double(std::numeric_limits<uint64_t>::max()/2)));}
 void sample(double ms){
  if(!std::isfinite(ms)||ms<0)return;
  maximum(max_us,microseconds(ms));
  bins[ms>=256?1024:size_t(ms*4)].fetch_add(1,std::memory_order_relaxed);
 }
 void event(uint64_t tick,uint64_t frequency){
  auto before=last.exchange(tick);if(!frequency||!before||tick<before)return;
  const double ms=double(tick-before)*1000/frequency;
  if(tick-before<frequency/4)sample(ms);
  else{excluded.fetch_add(1,std::memory_order_relaxed);maximum(excluded_max_us,microseconds(ms));}
 }
 struct Values {uint64_t n=0,overflow=0,excluded_gaps=0;double p50=0,p95=0,p99=0,lifetime_max_ms=0,excluded_lifetime_max_ms=0;};
 Values take(){std::array<uint64_t,1025> b{};Values v;for(size_t i=0;i<b.size();++i){b[i]=bins[i].exchange(0);v.n+=b[i];}
  v.overflow=b.back();v.lifetime_max_ms=double(max_us.load())/1000;v.excluded_gaps=excluded.exchange(0);v.excluded_lifetime_max_ms=double(excluded_max_us.load())/1000;
  if(!v.n)return v;
  // Upper bounds avoid claiming that a bucket's lower edge is the measured
  // percentile. Lifetime maxima are not reset, so an asynchronous drain cannot
  // detach an overflow sample from its valid upper bound.
  auto percentile=[&](double p){uint64_t acc=0;for(size_t i=0;i<b.size();++i){acc+=b[i];if(double(acc)>=v.n*p)return i==1024?std::max(256.,v.lifetime_max_ms):(i+1)*.25;}return v.lifetime_max_ms;};
  v.p50=percentile(.5);v.p95=percentile(.95);v.p99=percentile(.99);return v;
 }
};
