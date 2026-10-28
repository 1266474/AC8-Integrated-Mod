#pragma once

// Keep bounded 10-second summaries on for this investigation build. F5 still
// toggles capture. No per-frame file writes or formatting on input producers.
std::atomic<bool> perf_enabled{true};
std::atomic<bool> perf_flush{false};
struct PerfCounter {
    std::atomic<unsigned long long> count{0},total_us{0},max_us{0};
    void add(unsigned long long us) {
        count.fetch_add(1,std::memory_order_relaxed);
        total_us.fetch_add(us,std::memory_order_relaxed);
        auto old=max_us.load(std::memory_order_relaxed);
        while(old<us && !max_us.compare_exchange_weak(old,us,std::memory_order_relaxed)) {}
    }
};
PerfCounter perf_script,perf_bridge,perf_camera,perf_frame_gap;
PerfCounter perf_raw_callback,perf_raw_input_wait,perf_fallback_plan,perf_exact_solver;
PerfCounter perf_lua_callback;
PerfCounter perf_camera_host;
std::array<PerfCounter,64> perf_pw_callbacks;
std::atomic<unsigned long long> perf_unfinished_callbacks{0};
std::atomic<unsigned long long> perf_other_inputs{0},perf_player_inputs{0},perf_hitches{0};
LARGE_INTEGER perf_frequency{};
unsigned long long perf_clock() {
    LARGE_INTEGER value{}; QueryPerformanceCounter(&value);
    return static_cast<unsigned long long>(value.QuadPart);
}
unsigned long long perf_us(unsigned long long ticks) {
    return ticks*1000000ull/static_cast<unsigned long long>(perf_frequency.QuadPart);
}
struct PerfSpan {
    PerfCounter& counter;
    unsigned long long start;
    explicit PerfSpan(PerfCounter& c):counter(c),start(perf_enabled.load()?perf_clock():0) {}
    PerfSpan(PerfCounter& c,bool collect):counter(c),start(collect?perf_clock():0) {}
    ~PerfSpan() { if(start) counter.add(perf_us(perf_clock()-start)); }
};
unsigned long long script_start=0,previous_frame_start=0; // Game-thread only.
unsigned long long callback_start=0; // Paired begin()/begin(1), game-thread only.

struct LogRecord { unsigned long long tick=0; char message[1024]{}; };
std::array<LogRecord,64> log_queue;
size_t log_count=0;
std::mutex log_mutex;
std::atomic<unsigned long long> dropped_logs{0};
std::atomic<bool> logger_started{false};

// Never wait for a disk or for the logger. Drop bounded diagnostics on contention.
void log_line(const char* format, ...) {
    LogRecord record; record.tick=GetTickCount64();
    va_list args; va_start(args,format);
    vsnprintf(record.message,sizeof(record.message),format,args); va_end(args);
    std::unique_lock<std::mutex> lock(log_mutex,std::try_to_lock);
    if(!lock.owns_lock() || log_count==log_queue.size()) { ++dropped_logs; return; }
    log_queue[log_count++]=record;
}

void write_log_record(const LogRecord& record) {
    // This function is called ONLY by the background logger.
    if(journal==INVALID_HANDLE_VALUE) {
        wchar_t folder[MAX_PATH]{},path[MAX_PATH]{};
        swprintf_s(folder,L"%s\\..\\Logs",module_folder);
        CreateDirectoryW(folder,nullptr);
        for(int index=1;index<10000;++index) {
            swprintf_s(path,L"%s\\MouseAim-%05d.log",folder,index);
            journal=CreateFileW(path,GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
            if(journal!=INVALID_HANDLE_VALUE || GetLastError()!=ERROR_FILE_EXISTS) break;
        }
    }
    if(journal!=INVALID_HANDLE_VALUE) {
        char line[1200]{}; DWORD written=0;
        const int length=snprintf(line,sizeof(line),"%llu %s\r\n",record.tick,record.message);
        WriteFile(journal,line,static_cast<DWORD>(length),&written,nullptr);
    }
}
void report_counter(const char* name,PerfCounter& c,bool emit) {
    const auto n=c.count.exchange(0),total=c.total_us.exchange(0),peak=c.max_us.exchange(0);
    if(emit) log_line("PERF %s samples=%llu avg_us=%.2f max_us=%llu",name,n,n?double(total)/n:0,peak);
}
void logger_loop() {
    unsigned long long report_at=GetTickCount64();
    std::array<LogRecord,64> batch;
    for(;;) {
        size_t count=0;
        {
            std::unique_lock<std::mutex> lock(log_mutex,std::try_to_lock);
            if(lock.owns_lock()) {
                count=log_count;
                std::copy_n(log_queue.begin(),count,batch.begin());
                log_count=0;
            }
        }
        for(size_t i=0;i<count;++i) write_log_record(batch[i]);
        if(count) {
            FILE* status=nullptr;
            if(_wfopen_s(&status,status_path,L"w")==0 && status) {
                fprintf(status,"%s\n",batch[count-1].message); fclose(status);
            }
        }
        const bool final_report=perf_flush.exchange(false);
        if(final_report || GetTickCount64()-report_at>=10000) {
            report_at=GetTickCount64();
            const bool emit=perf_enabled.load() || final_report;
            report_counter("script_wall",perf_script,emit);
            report_counter("native_bridge",perf_bridge,emit);
            report_counter("camera_own_work",perf_camera,emit);
            report_counter("frame_gap",perf_frame_gap,emit);
            report_counter("raw_data_callback_sampled_1of64",perf_raw_callback,emit);
            report_counter("raw_inbox_wait_sampled_1of64",perf_raw_input_wait,emit);
            report_counter("fallback_plan",perf_fallback_plan,emit);
            report_counter("exact_solver",perf_exact_solver,emit);
            report_counter("lua_callback_wall",perf_lua_callback,emit);
            report_counter("camera_host_update",perf_camera_host,emit);
            for(size_t i=0;i<perf_pw_callbacks.size();++i){
                auto& c=perf_pw_callbacks[i];
                if(!c.count.load(std::memory_order_relaxed))continue;
                char label[40]{};snprintf(label,sizeof(label),"pw_callback_%zu",i);
                report_counter(label,c,emit);
            }
            const auto unfinished=perf_unfinished_callbacks.exchange(0);
            if(emit||unfinished)log_line("PERF lua_callback_unfinished=%llu (missing finish, incomplete samples excluded)",unfinished);
            const auto other=perf_other_inputs.exchange(0),player=perf_player_inputs.exchange(0);
            const auto hitches=perf_hitches.exchange(0),dropped=dropped_logs.exchange(0);
            if(emit || dropped) log_line("PERF input_player=%llu input_other=%llu gaps_over_50ms=%llu dropped_logs=%llu",player,other,hitches,dropped);
        }
        shadow_drain();fe_runtime::trace_drain(module_folder);
        Sleep(100);
    }
}
