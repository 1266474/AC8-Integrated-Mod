#pragma once
#include <atomic>
#include <cstdint>
#include <algorithm>
#include <mutex>
struct MouseDelta {int32_t x=0,y=0;};
class PairedMouse {
    std::atomic<uint64_t> value{0};
    static int32_t clamp(int64_t v){return int32_t(std::clamp(v,int64_t(INT32_MIN),int64_t(INT32_MAX)));}
    static uint64_t pack(int32_t x,int32_t y){return uint64_t(uint32_t(x))|(uint64_t(uint32_t(y))<<32);}
    static MouseDelta unpack(uint64_t v){return {int32_t(uint32_t(v)),int32_t(uint32_t(v>>32))};}
public:
    void add(int32_t x,int32_t y){
        auto old=value.load(std::memory_order_relaxed);
        for(;;){auto d=unpack(old);auto next=pack(clamp(int64_t(d.x)+x),clamp(int64_t(d.y)+y));
            if(value.compare_exchange_weak(old,next,std::memory_order_relaxed))return;}
    }
    MouseDelta take(){return unpack(value.exchange(0,std::memory_order_relaxed));}
    void clear(){value.store(0,std::memory_order_relaxed);}
};

// Only the input inbox is serialized here. Producers must never acquire the
// flight controller's target lock: a raw-input callback can run on another
// thread while the game frame is still computing its control solution.
class MouseInputInbox {
    PairedMouse pending;
    std::mutex input_mutex;
    std::atomic<uint64_t> generation{1};
public:
    using Generation=uint64_t;
    // Capture before reading an input packet. A producer can be suspended
    // across pause/resume or aircraft replacement while all bool gates return
    // to true; only the generation identifies that packet as belonging to the
    // already-cleared lifecycle.
    Generation token()const{return generation.load(std::memory_order_acquire);}
    template<class Allowed, class Acquired>
    bool add_if(Generation expected,int32_t x,int32_t y,Allowed allowed,Acquired acquired){
        std::lock_guard<std::mutex> lock(input_mutex);
        acquired();
        // Recheck lifecycle gates after acquiring the inbox lock. A producer
        // waiting across pause/release must not reintroduce the cleared input.
        if(expected!=generation.load(std::memory_order_relaxed)||!allowed())return false;
        pending.add(x,y);return true;
    }
    template<class Allowed>
    bool add_if(Generation expected,int32_t x,int32_t y,Allowed allowed){
        return add_if(expected,x,y,allowed,[]{});
    }
    MouseDelta take(){std::lock_guard<std::mutex> lock(input_mutex);return pending.take();}
    void clear(){
        std::lock_guard<std::mutex> lock(input_mutex);
        pending.clear();generation.fetch_add(1,std::memory_order_release);
    }
};
