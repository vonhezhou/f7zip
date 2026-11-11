#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Job F7Job;
F7Job* f7_job_create(void);
void f7_job_destroy(F7Job* job);
void f7_job_cancel(F7Job* job);
char* f7_job_progress(F7Job* job);
void f7_free(char* value);
void f7_job_codepage(F7Job* job, uint32_t codePage);
void f7_job_filename_normalization(F7Job* job, uint32_t mode);
void f7_job_volume_size(F7Job* job, uint64_t size);
void f7_job_compression_parameters(F7Job* job, const char* method,
    uint32_t dictionaryMiB, uint32_t threads, int32_t solidMiB);
char* f7_run(F7Job* job, const char* engine, const char* operation, const char* archive,
    const char* destination, const char* password, const char* format, int level,
    const char* const* inputs, int inputCount, const uint32_t* indices, int indexCount);

#ifdef __cplusplus
}
#endif
