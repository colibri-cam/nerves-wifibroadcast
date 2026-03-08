#include <erl_nif.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "fec.h"

typedef struct {
    fec_t *code;
    unsigned k;
    unsigned n;
} fec_resource_t;

static ErlNifResourceType *fec_resource_type = NULL;
static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;

static void fec_resource_dtor(ErlNifEnv *env, void *obj) {
    fec_resource_t *resource = (fec_resource_t *)obj;
    (void)env;

    if (resource->code != NULL) {
        fec_free(resource->code);
        resource->code = NULL;
    }
}

static int get_uint_arg(ErlNifEnv *env, ERL_NIF_TERM term, unsigned *value) {
    return enif_get_uint(env, term, value);
}

static int inspect_binary_list(ErlNifEnv *env,
                               ERL_NIF_TERM list,
                               unsigned expected_len,
                               ErlNifBinary *binaries) {
    unsigned length = 0;
    ERL_NIF_TERM head;
    ERL_NIF_TERM tail = list;
    unsigned i = 0;

    if (!enif_get_list_length(env, list, &length) || length != expected_len) {
        return 0;
    }

    while (enif_get_list_cell(env, tail, &head, &tail)) {
        if (!enif_inspect_binary(env, head, &binaries[i])) {
            return 0;
        }

        i += 1;
    }

    return i == expected_len;
}

static int inspect_uint_list(ErlNifEnv *env,
                             ERL_NIF_TERM list,
                             unsigned expected_len,
                             unsigned *values) {
    unsigned length = 0;
    ERL_NIF_TERM head;
    ERL_NIF_TERM tail = list;
    unsigned i = 0;

    if (!enif_get_list_length(env, list, &length) || length != expected_len) {
        return 0;
    }

    while (enif_get_list_cell(env, tail, &head, &tail)) {
        if (!enif_get_uint(env, head, &values[i])) {
            return 0;
        }

        i += 1;
    }

    return i == expected_len;
}

static void free_temp_inputs(unsigned char **temp_inputs, unsigned count) {
    unsigned i;

    if (temp_inputs == NULL) {
        return;
    }

    for (i = 0; i < count; i++) {
        if (temp_inputs[i] != NULL) {
            enif_free(temp_inputs[i]);
        }
    }

    enif_free(temp_inputs);
}

static int prepare_input_ptrs(ErlNifBinary *binaries,
                              unsigned count,
                              unsigned shard_size,
                              const gf **inputs,
                              unsigned char **temp_inputs) {
    unsigned i;

    for (i = 0; i < count; i++) {
        if (binaries[i].size > shard_size) {
            return 0;
        }

        if (binaries[i].size == shard_size) {
            inputs[i] = binaries[i].data;
            temp_inputs[i] = NULL;
        } else {
            temp_inputs[i] = enif_alloc(shard_size);

            if (temp_inputs[i] == NULL) {
                return 0;
            }

            memset(temp_inputs[i], 0, shard_size);
            memcpy(temp_inputs[i], binaries[i].data, binaries[i].size);
            inputs[i] = temp_inputs[i];
        }
    }

    return 1;
}

static ERL_NIF_TERM build_binary_list(ErlNifEnv *env, ERL_NIF_TERM *terms, unsigned count) {
    unsigned i;
    ERL_NIF_TERM list = enif_make_list(env, 0);

    for (i = count; i > 0; i--) {
        list = enif_make_list_cell(env, terms[i - 1], list);
    }

    return list;
}

static ERL_NIF_TERM new_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    unsigned k = 0;
    unsigned n = 0;
    fec_resource_t *resource = NULL;
    ERL_NIF_TERM resource_term;

    if (argc != 2) {
        return enif_make_badarg(env);
    }

    if (!get_uint_arg(env, argv[0], &k) || !get_uint_arg(env, argv[1], &n) ||
        k < 1 || n < 1 || k > n || n > 256) {
        return enif_make_badarg(env);
    }

    resource = enif_alloc_resource(fec_resource_type, sizeof(*resource));

    if (resource == NULL) {
        return atom_error;
    }

    resource->k = k;
    resource->n = n;
    resource->code = fec_new((uint16_t)k, (uint16_t)n);

    if (resource->code == NULL) {
        enif_release_resource(resource);
        return atom_error;
    }

    resource_term = enif_make_resource(env, resource);
    enif_release_resource(resource);

    return resource_term;
}

static ERL_NIF_TERM encode_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    fec_resource_t *resource = NULL;
    ErlNifBinary *binaries = NULL;
    const gf **inputs = NULL;
    unsigned char **temp_inputs = NULL;
    gf **outputs = NULL;
    ERL_NIF_TERM *output_terms = NULL;
    unsigned shard_size = 0;
    unsigned parity_count = 0;
    unsigned i;
    ERL_NIF_TERM result;

    if (argc != 3) {
        return enif_make_badarg(env);
    }

    if (!enif_get_resource(env, argv[0], fec_resource_type, (void **)&resource) ||
        !get_uint_arg(env, argv[2], &shard_size) || shard_size < 1) {
        return enif_make_badarg(env);
    }

    binaries = enif_alloc(sizeof(ErlNifBinary) * resource->k);
    inputs = enif_alloc(sizeof(gf *) * resource->k);
    temp_inputs = enif_alloc(sizeof(unsigned char *) * resource->k);
    parity_count = resource->n - resource->k;
    outputs = parity_count > 0 ? enif_alloc(sizeof(gf *) * parity_count) : NULL;
    output_terms = parity_count > 0 ? enif_alloc(sizeof(ERL_NIF_TERM) * parity_count) : NULL;

    if (binaries == NULL || inputs == NULL || temp_inputs == NULL ||
        (parity_count > 0 && (outputs == NULL || output_terms == NULL))) {
        result = atom_error;
        goto encode_cleanup;
    }

    memset(temp_inputs, 0, sizeof(unsigned char *) * resource->k);

    if (!inspect_binary_list(env, argv[1], resource->k, binaries) ||
        !prepare_input_ptrs(binaries, resource->k, shard_size, inputs, temp_inputs)) {
        result = enif_make_badarg(env);
        goto encode_cleanup;
    }

    for (i = 0; i < parity_count; i++) {
        outputs[i] = enif_make_new_binary(env, shard_size, &output_terms[i]);
    }

    fec_encode(resource->code, inputs, outputs, shard_size);
    result = enif_make_tuple2(env, atom_ok, build_binary_list(env, output_terms, parity_count));

encode_cleanup:
    free_temp_inputs(temp_inputs, resource != NULL ? resource->k : 0);
    if (binaries != NULL) enif_free(binaries);
    if (inputs != NULL) enif_free(inputs);
    if (outputs != NULL) enif_free(outputs);
    if (output_terms != NULL) enif_free(output_terms);
    return result;
}

static ERL_NIF_TERM decode_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    fec_resource_t *resource = NULL;
    ErlNifBinary *binaries = NULL;
    const gf **inputs = NULL;
    unsigned char **temp_inputs = NULL;
    gf **outputs = NULL;
    unsigned *indexes = NULL;
    unsigned *missing_indexes = NULL;
    ERL_NIF_TERM *output_terms = NULL;
    unsigned shard_size = 0;
    unsigned missing_count = 0;
    unsigned i;
    ERL_NIF_TERM result;

    if (argc != 5) {
        return enif_make_badarg(env);
    }

    if (!enif_get_resource(env, argv[0], fec_resource_type, (void **)&resource) ||
        !get_uint_arg(env, argv[4], &shard_size) || shard_size < 1 ||
        !enif_get_list_length(env, argv[3], &missing_count)) {
        return enif_make_badarg(env);
    }

    binaries = enif_alloc(sizeof(ErlNifBinary) * resource->k);
    inputs = enif_alloc(sizeof(gf *) * resource->k);
    temp_inputs = enif_alloc(sizeof(unsigned char *) * resource->k);
    indexes = enif_alloc(sizeof(unsigned) * resource->k);
    missing_indexes = missing_count > 0 ? enif_alloc(sizeof(unsigned) * missing_count) : NULL;
    outputs = missing_count > 0 ? enif_alloc(sizeof(gf *) * missing_count) : NULL;
    output_terms = missing_count > 0 ? enif_alloc(sizeof(ERL_NIF_TERM) * missing_count) : NULL;

    if (binaries == NULL || inputs == NULL || temp_inputs == NULL || indexes == NULL ||
        (missing_count > 0 && (missing_indexes == NULL || outputs == NULL || output_terms == NULL))) {
        result = atom_error;
        goto decode_cleanup;
    }

    memset(temp_inputs, 0, sizeof(unsigned char *) * resource->k);

    if (!inspect_binary_list(env, argv[1], resource->k, binaries) ||
        !inspect_uint_list(env, argv[2], resource->k, indexes) ||
        !(missing_count == 0 || inspect_uint_list(env, argv[3], missing_count, missing_indexes)) ||
        !prepare_input_ptrs(binaries, resource->k, shard_size, inputs, temp_inputs)) {
        result = enif_make_badarg(env);
        goto decode_cleanup;
    }

    for (i = 0; i < resource->k; i++) {
        if (indexes[i] >= resource->n) {
            result = enif_make_badarg(env);
            goto decode_cleanup;
        }
    }

    for (i = 0; i < missing_count; i++) {
        if (missing_indexes[i] >= resource->k) {
            result = enif_make_badarg(env);
            goto decode_cleanup;
        }

        outputs[i] = enif_make_new_binary(env, shard_size, &output_terms[i]);
    }

    if (missing_count > 0) {
        fec_decode(resource->code, inputs, outputs, indexes, shard_size);
    }

    result = enif_make_tuple2(env, atom_ok, build_binary_list(env, output_terms, missing_count));

decode_cleanup:
    free_temp_inputs(temp_inputs, resource != NULL ? resource->k : 0);
    if (binaries != NULL) enif_free(binaries);
    if (inputs != NULL) enif_free(inputs);
    if (indexes != NULL) enif_free(indexes);
    if (missing_indexes != NULL) enif_free(missing_indexes);
    if (outputs != NULL) enif_free(outputs);
    if (output_terms != NULL) enif_free(output_terms);
    return result;
}

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
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

    if (fec_resource_type == NULL) {
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
