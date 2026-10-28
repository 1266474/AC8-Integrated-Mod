#include "src/paired_mouse.h"
#include "src/hud_timing.h"
#include <atomic>
#include <chrono>
#include <cmath>
#include <future>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <thread>
#include <vector>

static unsigned checks=0;
static void require(bool ok,const char* message){++checks;if(!ok)throw std::runtime_error(message);}

static void paired_saturation(){
    PairedMouse queue;
    queue.add(INT32_MAX,INT32_MIN);queue.add(1,-1);
    const auto full=queue.take();
    require(full.x==INT32_MAX&&full.y==INT32_MIN,"paired saturation changed");
    const auto empty=queue.take();require(empty.x==0&&empty.y==0,"take did not clear both axes");
}

static void concurrent_pairing(){
    MouseInputInbox inbox;std::atomic<unsigned> done{0};
    constexpr int producers=4,per_producer=25000;
    std::vector<std::thread> threads;
    for(int i=0;i<producers;++i)threads.emplace_back([&]{
        for(int n=0;n<per_producer;++n)inbox.add_if(inbox.token(),1,-1,[]{return true;});
        done.fetch_add(1);
    });
    int64_t x=0,y=0;bool paired=true;
    while(done.load()!=producers){auto d=inbox.take();paired=paired&&(d.x==-d.y);x+=d.x;y+=d.y;std::this_thread::yield();}
    for(auto& t:threads)t.join();
    auto d=inbox.take();paired=paired&&(d.x==-d.y);x+=d.x;y+=d.y;
    require(paired,"concurrent consume split an X/Y pair");
    require(x==producers*per_producer&&y==-x,"concurrent input was lost or duplicated");
}

static void gate_and_clear(){
    MouseInputInbox inbox;std::atomic<bool> accepting{true};
    std::promise<void> inside_gate,release_gate;auto gate_ready=inside_gate.get_future();auto gate_release=release_gate.get_future();
    inbox.add_if(inbox.token(),17,-17,[]{return true;});
    auto producer=std::async(std::launch::async,[&]{return inbox.add_if(inbox.token(),31,-31,[&]{
        inside_gate.set_value();gate_release.wait();
        return accepting.load();
    });});
    gate_ready.wait();
    accepting.store(false); // Pause/release publishes the gate before clear.
    auto clear=std::async(std::launch::async,[&]{inbox.clear();});
    release_gate.set_value();
    const bool accepted=producer.get();clear.get();
    require(!accepted,"producer did not recheck lifecycle gate inside inbox lock");
    auto d=inbox.take();require(d.x==0&&d.y==0,"pause/release retained stale input");
    require(!inbox.add_if(inbox.token(),5,-5,[&]{return accepting.load();}),"paused producer was accepted");
    accepting.store(true);
    inbox.add_if(inbox.token(),7,-7,[&]{return accepting.load();});d=inbox.take();
    require(d.x==7&&d.y==-7,"new input after resume was not preserved");
    inbox.add_if(inbox.token(),100,-100,[]{return true;});inbox.clear();
    inbox.add_if(inbox.token(),2,-2,[]{return true;});d=inbox.take();
    require(d.x==2&&d.y==-2,"recenter clear was not an inbox boundary");
}

static void controller_lock_isolation(){
    MouseInputInbox inbox;std::mutex controller_mutex;
    std::unique_lock controller_busy(controller_mutex);
    auto producer=std::async(std::launch::async,[&]{return inbox.add_if(inbox.token(),3,-3,[]{return true;});});
    const bool independent=producer.wait_for(std::chrono::seconds(2))==std::future_status::ready;
    controller_busy.unlock();const bool accepted=producer.get();
    require(independent&&accepted,"input waited for unrelated controller work");
}

static void old_packet_generation(){
    MouseInputInbox inbox;std::atomic<bool> accepting{true};
    std::promise<void> read_started,finish_read;auto started=read_started.get_future();auto finish=finish_read.get_future();
    auto producer=std::async(std::launch::async,[&]{
        const auto before_read=inbox.token();
        read_started.set_value();finish.wait(); // Simulate a suspended GetRawInputData/GetDeviceState call.
        return inbox.add_if(before_read,41,-41,[&]{return accepting.load();});
    });
    started.wait();
    accepting.store(false);inbox.clear();accepting.store(true); // A whole pause/resume cycle.
    finish_read.set_value();
    require(!producer.get(),"old input survived a complete pause/resume with true bool gates");
    auto d=inbox.take();require(d.x==0&&d.y==0,"stale generation reached the consumer");
    const auto fresh=inbox.token();
    require(inbox.add_if(fresh,5,-5,[&]{return accepting.load();}),"new generation was rejected after resume");
    d=inbox.take();require(d.x==5&&d.y==-5,"new generation input was changed");

    const auto old_pawn=inbox.token();
    accepting.store(false);inbox.clear();inbox.clear();accepting.store(true); // Release, then acquire another pawn.
    require(!inbox.add_if(old_pawn,99,-99,[&]{return accepting.load();}),"old aircraft's input reached a new pawn");
    require(inbox.add_if(inbox.token(),7,-7,[]{return true;}),"new aircraft's input was rejected");
    d=inbox.take();require(d.x==7&&d.y==-7,"aircraft generation boundary retained old input");

    const auto size_query_token=inbox.token(); // Size-only query submits nothing.
    inbox.clear();
    const auto payload_call_token=inbox.token(); // Each payload-bearing API call snapshots independently.
    require(size_query_token!=payload_call_token,"clear did not advance generation");
    require(inbox.add_if(payload_call_token,11,-11,[]{return true;}),"size-query token incorrectly governed payload call");
    d=inbox.take();require(d.x==11&&d.y==-11,"payload after size-query lifecycle transition was lost");
}

static void long_tail_statistics(){
    HudTiming timing;
    for(int i=0;i<90;++i)timing.sample(8.1);
    for(int i=0;i<8;++i)timing.sample(75.1);
    timing.sample(147.53);timing.sample(400);
    timing.sample(-1);timing.sample(std::numeric_limits<double>::quiet_NaN());
    timing.sample(std::numeric_limits<double>::infinity());
    const auto v=timing.take();
    require(v.n==100,"invalid duration polluted timing samples");
    require(v.p50>=8.1&&v.p50<=8.35,"median is not a 0.25ms bucket upper bound");
    require(v.p95>=75.1&&v.p95<=75.35,"75ms tail was truncated to 32ms");
    require(v.p99>=147.53&&v.p99<=147.78,"147ms tail was truncated");
    require(v.overflow==1&&v.lifetime_max_ms==400,"overflow lost its real maximum");
    const auto empty=timing.take();
    require(empty.n==0&&empty.lifetime_max_ms==400,"drain corrupted lifetime maximum");
    timing.sample(600);const auto overflow=timing.take();
    require(overflow.p99>=600&&overflow.overflow==1,"overflow percentile pretended to be a finite bucket edge");
    HudTiming events;events.event(1000,1000);events.event(1010,1000);events.event(1410,1000);
    const auto e=events.take();
    require(e.n==1&&e.excluded_gaps==1&&e.excluded_lifetime_max_ms==400,"long event gaps disappeared without diagnostics");
}

int main(){
    try{
        paired_saturation();concurrent_pairing();gate_and_clear();controller_lock_isolation();old_packet_generation();long_tail_statistics();
        std::cout<<"PASS native input isolation/lifecycle/concurrency/long-tail statistics: "<<checks<<" checks\n";
        return 0;
    }catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<"\n";return 1;}
}
