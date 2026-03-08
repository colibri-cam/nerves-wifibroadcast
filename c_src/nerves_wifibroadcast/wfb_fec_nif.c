#include <erl_nif.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "zfex.h"

typedef struct {
    fec_t *code;
    unsigned k;
    unsigned n;
} fec_resource_t;

static ErlNifResourceType *fec_resource_type = NULL;
static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;

static void fec_resource_dtor(ErlNifEnv *env, void *obj)
{
    fec_resource_t *resource = (fec_resource_t *)obj;
    (void)env;

    if (resource->code != NULL)
    {
        fec_free(resource->code);
        resource->code = NULL;
    }
}

static int get_uint_arg(ErlNifEnv *env, ERL_NIF_TERM term, unsigned *value)
{
    return enif_get_uint(env, term, value);
}

static int inspect_binary_list(ErlNifEnv *env,
                               ERL_NIF_TERM list,
                               unsigned expected_len,
                               ErlNifBinary *binaries)
{
    unsigned length = 0;
    ERL_NIF_TERM head;
    ERL_NIF_TERM tail = list;
    unsigned i = 0;

    if (!enif_get_list_length(env, list, &length) || length != expected_len)
    {
        return 0;
    }

    while (enif_get_list_cell(env, tail, &head, &tail))
    {
        if (!enif_inspect_binary(env, head, &binaries[i]))
        {
            return 0;
        }

        i += 1;
    }

    return i == expected_len;
}

static int inspect_uint_list(ErlNifEnv *env,
                             ERL_NIF_TERM list,
                             unsigned expected_len,
                             unsigned *values)
{
    unsigned length = 0;
    ERL_NIF_TERM head;
    ERL_NIF_TERM tail = list;
    unsigned i = 0;

    if (!enif_get_list_length(env, list, &length) || length != expected_len)
    {
        return 0;
    }

    while (enif_get_list_cell(env, tail, &head, &tail))
    {
        if (!enif_get_uint(env, head, &values[i]))
        {
            return 0;
        }

        i += 1;
    }

    return i == expected_len;
}

static gf **alloc_aligned_blocks(unsigned count, size_t aligned_shard_size)
{
    gf **blocks = NULL;
    unsigned i = 0;

    if (count == 0)
    {
        return NULL;
    }

    blocks = enif_alloc(sizeof(gf *) * count);
    if (blocks == NULL)
    {
        return NULL;
    }

    memset(blocks, 0, sizeof(gf *) * count);

    for (i = 0; i < count; i++)
    {
        if (posix_memalign((void **)&blocks[i], ZFEX_SIMD_ALIGNMENT, aligned_shard_size) != 0)
        {
            unsigned j;

            for (j = 0; j < i; j++)
            {
                free(blocks[j]);
            }

            enif_free(blocks);
            return NULL;
        }

        memset(blocks[i], 0, aligned_shard_size);
    }

    return blocks;
}

static void free_aligned_blocks(gf **blocks, unsigned count)
{
    unsigned i;

    if (blocks == NULL)
    {
        return;
    }

    for (i = 0; i < count; i++)
    {
        if (blocks[i] != NULL)
        {
            free(blocks[i]);
        }
    }

    enif_free(blocks);
}

static int copy_binaries_to_aligned_blocks(ErlNifBinary *binaries,
                                           unsigned count,
                                           size_t shard_size,
                                           size_t aligned_shard_size,
                                           gf **blocks)
{
    unsigned i;

    for (i = 0; i < count; i++)
    {
        if (binaries[i].size > shard_size)
        {
            return 0;
        }

        memset(blocks[i], 0, aligned_shard_size);
        memcpy(blocks[i], binaries[i].data, binaries[i].size);
    }

    return 1;
}

static int build_output_terms(ErlNifEnv *env,
                              gf **blocks,
                              unsigned count,
                              size_t shard_size,
                              ERL_NIF_TERM *terms)
{
    unsigned i;

    for (i = 0; i < count; i++)
    {
        unsigned char *binary = enif_make_new_binary(env, shard_size, &terms[i]);
        if (binary == NULL)
        {
            return 0;
        }

        memcpy(binary, blocks[i], shard_size);
    }

    return 1;
}

static ERL_NIF_TERM build_binary_list(ErlNifEnv *env, ERL_NIF_TERM *terms, unsigned count)
{
    unsigned i;
    ERL_NIF_TERM list = enif_make_list(env, 0);

    for (i = count; i > 0; i--)
    {
        list = enif_make_list_cell(env, terms[i - 1], list);
    }

    return list;
}

static int count_missing_sources(const unsigned *indexes, unsigned k)
{
    unsigned i;
    int missing = 0;

    for (i = 0; i < k; i++)
    {
        if (indexes[i] >= k)
        {
            missing += 1;
        }
    }

    return missing;
}

static int validate_missing_indexes(const unsigned *missing_indexes,
                                    unsigned missing_count,
                                    const unsigned *indexes,
                                    unsigned k,
                                    unsigned n)
{
    unsigned i;
    unsigned j;

    for (i = 0; i < k; i++)
    {
        if (indexes[i] >= n)
        {
            return 0;
        }
    }

    if ((unsigned)count_missing_sources(indexes, k) != missing_count)
    {
        return 0;
    }

    for (i = 0; i < missing_count; i++)
    {
        if (missing_indexes[i] >= k || indexes[missing_indexes[i]] < k)
        {
            return 0;
        }

        for (j = i + 1; j < missing_count; j++)
        {
            if (missing_indexes[i] == missing_indexes[j])
            {
                return 0;
            }
        }
    }

    return 1;
}

static unsigned find_missing_output_slot(const unsigned *indexes,
                                         unsigned k,
                                         unsigned missing_index)
{
    unsigned i;
    unsigned slot = 0;

    for (i = 0; i < k; i++)
    {
        if (indexes[i] >= k)
        {
            if (i == missing_index)
            {
                return slot;
            }

            slot += 1;
        }
    }

    return k;
}

static ERL_NIF_TERM new_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    unsigned k = 0;
    unsigned n = 0;
    fec_resource_t *resource = NULL;
    ERL_NIF_TERM resource_term;
    zfex_status_code_t rc;

    if (argc != 2)
    {
        return enif_make_badarg(env);
    }

    if (!get_uint_arg(env, argv[0], &k) || !get_uint_arg(env, argv[1], &n) ||
        k < 1 || n < 1 || k > n || n >= 256)
    {
        return enif_make_badarg(env);
    }

    resource = enif_alloc_resource(fec_resource_type, sizeof(*resource));
    if (resource == NULL)
    {
        return atom_error;
    }

    memset(resource, 0, sizeof(*resource));
    resource->k = k;
    resource->n = n;

    rc = fec_new((uint16_t)k, (uint16_t)n, &resource->code);
    if (rc != ZFEX_SC_OK || resource->code == NULL)
    {
        enif_release_resource(resource);
        return atom_error;
    }

    resource_term = enif_make_resource(env, resource);
    enif_release_resource(resource);

    return resource_term;
}

static ERL_NIF_TERM encode_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    fec_resource_t *resource = NULL;
    ErlNifBinary *binaries = NULL;
    gf **inputs = NULL;
    gf **outputs = NULL;
    ERL_NIF_TERM *output_terms = NULL;
    unsigned shard_size = 0;
    size_t aligned_shard_size = 0;
    unsigned parity_count = 0;
    ERL_NIF_TERM result = atom_error;
    zfex_status_code_t rc;

    if (argc != 3)
    {
        return enif_make_badarg(env);
    }

    if (!enif_get_resource(env, argv[0], fec_resource_type, (void **)&resource) ||
        !get_uint_arg(env, argv[2], &shard_size) || shard_size < 1)
    {
        return enif_make_badarg(env);
    }

    parity_count = resource->n - resource->k;
    if (parity_count == 0)
    {
        return enif_make_tuple2(env, atom_ok, enif_make_list(env, 0));
    }

    aligned_shard_size = ZFEX_ROUND_UP_SIMD((size_t)shard_size);

    binaries = enif_alloc(sizeof(ErlNifBinary) * resource->k);
    output_terms = enif_alloc(sizeof(ERL_NIF_TERM) * parity_count);
    if (binaries == NULL || output_terms == NULL)
    {
        goto encode_cleanup;
    }

    if (!inspect_binary_list(env, argv[1], resource->k, binaries))
    {
        result = enif_make_badarg(env);
        goto encode_cleanup;
    }

    inputs = alloc_aligned_blocks(resource->k, aligned_shard_size);
    outputs = alloc_aligned_blocks(parity_count, aligned_shard_size);
    if (inputs == NULL || outputs == NULL)
    {
        goto encode_cleanup;
    }

    if (!copy_binaries_to_aligned_blocks(binaries,
                                         resource->k,
                                         shard_size,
                                         aligned_shard_size,
                                         inputs))
    {
        result = enif_make_badarg(env);
        goto encode_cleanup;
    }

    rc = fec_encode_simd(resource->code,
                         (const gf * const *)inputs,
                         outputs,
                         aligned_shard_size);
    if (rc != ZFEX_SC_OK)
    {
        goto encode_cleanup;
    }

    if (!build_output_terms(env, outputs, parity_count, shard_size, output_terms))
    {
        goto encode_cleanup;
    }

    result = enif_make_tuple2(env, atom_ok, build_binary_list(env, output_terms, parity_count));

encode_cleanup:
    free_aligned_blocks(inputs, resource != NULL ? resource->k : 0);
    free_aligned_blocks(outputs, parity_count);
    if (binaries != NULL) enif_free(binaries);
    if (output_terms != NULL) enif_free(output_terms);
    return result;
}

static ERL_NIF_TERM decode_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    fec_resource_t *resource = NULL;
    ErlNifBinary *binaries = NULL;
    gf **inputs = NULL;
    gf **outputs = NULL;
    unsigned *indexes = NULL;
    unsigned *missing_indexes = NULL;
    ERL_NIF_TERM *output_terms = NULL;
    unsigned shard_size = 0;
    size_t aligned_shard_size = 0;
    unsigned missing_count = 0;
    unsigned i;
    ERL_NIF_TERM result = atom_error;
    zfex_status_code_t rc;

    if (argc != 5)
    {
        return enif_make_badarg(env);
    }

    if (!enif_get_resource(env, argv[0], fec_resource_type, (void **)&resource) ||
        !get_uint_arg(env, argv[4], &shard_size) || shard_size < 1 ||
        !enif_get_list_length(env, argv[3], &missing_count))
    {
        return enif_make_badarg(env);
    }

    if (missing_count == 0)
    {
        return enif_make_tuple2(env, atom_ok, enif_make_list(env, 0));
    }

    aligned_shard_size = ZFEX_ROUND_UP_SIMD((size_t)shard_size);

    binaries = enif_alloc(sizeof(ErlNifBinary) * resource->k);
    indexes = enif_alloc(sizeof(unsigned) * resource->k);
    missing_indexes = enif_alloc(sizeof(unsigned) * missing_count);
    output_terms = enif_alloc(sizeof(ERL_NIF_TERM) * missing_count);
    if (binaries == NULL || indexes == NULL || missing_indexes == NULL || output_terms == NULL)
    {
        goto decode_cleanup;
    }

    if (!inspect_binary_list(env, argv[1], resource->k, binaries) ||
        !inspect_uint_list(env, argv[2], resource->k, indexes) ||
        !inspect_uint_list(env, argv[3], missing_count, missing_indexes) ||
        !validate_missing_indexes(missing_indexes, missing_count, indexes, resource->k, resource->n))
    {
        result = enif_make_badarg(env);
        goto decode_cleanup;
    }

    inputs = alloc_aligned_blocks(resource->k, aligned_shard_size);
    outputs = alloc_aligned_blocks(missing_count, aligned_shard_size);
    if (inputs == NULL || outputs == NULL)
    {
        goto decode_cleanup;
    }

    if (!copy_binaries_to_aligned_blocks(binaries,
                                         resource->k,
                                         shard_size,
                                         aligned_shard_size,
                                         inputs))
    {
        result = enif_make_badarg(env);
        goto decode_cleanup;
    }

    rc = fec_decode_simd(resource->code,
                         (const gf **)inputs,
                         outputs,
                         indexes,
                         aligned_shard_size);
    if (rc != ZFEX_SC_OK)
    {
        goto decode_cleanup;
    }

    for (i = 0; i < missing_count; i++)
    {
        unsigned slot = find_missing_output_slot(indexes, resource->k, missing_indexes[i]);
        unsigned char *binary;

        if (slot >= missing_count)
        {
            result = enif_make_badarg(env);
            goto decode_cleanup;
        }

        binary = enif_make_new_binary(env, shard_size, &output_terms[i]);
        if (binary == NULL)
        {
            goto decode_cleanup;
        }

        memcpy(binary, outputs[slot], shard_size);
    }

    result = enif_make_tuple2(env, atom_ok, build_binary_list(env, output_terms, missing_count));

decode_cleanup:
    free_aligned_blocks(inputs, resource != NULL ? resource->k : 0);
    free_aligned_blocks(outputs, missing_count);
    if (binaries != NULL) enif_free(binaries);
    if (indexes != NULL) enif_free(indexes);
    if (missing_indexes != NULL) enif_free(missing_indexes);
    if (output_terms != NULL) enif_free(output_terms);
    return result;
}

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
    int flags = ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER;

    (void)priv_data;
    (void)load_info;

    atom_ok = enif_make_atom(env, "ok");
    atom_error = enif_make_atom(env, "error");

    fec_resource_type = enif_open_resource_type(env,
                                                NULL,
                                                "wfb_fec_resource",
                                                fec_resource_dtor,
                                                flags,
                                                NULL);

    if (fec_resource_type == NULL)
    {
        return -1;
    }

    return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"new", 2, new_nif, 0},
    {"encode", 3, encode_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"decode", 5, decode_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND}
};

ERL_NIF_INIT(Elixir.NervesWifibroadcast.WFB.FecNif.Nif, nif_funcs, load, NULL, NULL, NULL)
