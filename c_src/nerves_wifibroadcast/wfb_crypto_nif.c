#include <erl_nif.h>
#include <sodium.h>
#include <stdint.h>
#include <string.h>

#define WFB_PACKET_DATA 0x01
#define WFB_PACKET_SESSION 0x02

typedef struct __attribute__((packed)) {
    uint8_t packet_type;
    uint8_t session_nonce[crypto_box_NONCEBYTES];
} wsession_hdr_t;

typedef struct __attribute__((packed)) {
    uint8_t packet_type;
    uint8_t data_nonce[crypto_aead_chacha20poly1305_NPUBBYTES];
} wblock_hdr_t;

typedef struct {
    unsigned char key[crypto_box_BEFORENMBYTES];
} box_key_resource_t;

static ErlNifResourceType *box_key_resource_type = NULL;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_ok;

static int inspect_binary(ErlNifEnv *env, ERL_NIF_TERM term, ErlNifBinary *binary) {
    return enif_inspect_binary(env, term, binary);
}

static ERL_NIF_TERM box_beforenm_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary tx_publickey;
    ErlNifBinary rx_secretkey;
    box_key_resource_t *resource = NULL;
    ERL_NIF_TERM resource_term;

    if (argc != 2) {
        return enif_make_badarg(env);
    }

    if (!inspect_binary(env, argv[0], &tx_publickey) ||
        !inspect_binary(env, argv[1], &rx_secretkey) ||
        tx_publickey.size != crypto_box_PUBLICKEYBYTES ||
        rx_secretkey.size != crypto_box_SECRETKEYBYTES) {
        return enif_make_badarg(env);
    }

    resource = enif_alloc_resource(box_key_resource_type, sizeof(*resource));

    if (resource == NULL) {
        return atom_error;
    }

    if (crypto_box_beforenm(resource->key, tx_publickey.data, rx_secretkey.data) != 0) {
        enif_release_resource(resource);
        return atom_error;
    }

    resource_term = enif_make_resource(env, resource);
    enif_release_resource(resource);

    return resource_term;
}

static ERL_NIF_TERM open_session_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary packet;
    box_key_resource_t *box_key = NULL;
    const wsession_hdr_t *header;
    const unsigned char *ciphertext;
    unsigned long long ciphertext_len;
    unsigned long long plaintext_len;
    ERL_NIF_TERM plaintext_term;
    unsigned char *plaintext;

    if (argc != 2) {
        return enif_make_badarg(env);
    }

    if (!inspect_binary(env, argv[0], &packet) ||
        !enif_get_resource(env, argv[1], box_key_resource_type, (void **)&box_key)) {
        return enif_make_badarg(env);
    }

    if (packet.size < sizeof(wsession_hdr_t) + crypto_box_MACBYTES) {
        return atom_error;
    }

    header = (const wsession_hdr_t *)packet.data;

    if (header->packet_type != WFB_PACKET_SESSION) {
        return atom_error;
    }

    ciphertext = packet.data + sizeof(wsession_hdr_t);
    ciphertext_len = packet.size - sizeof(wsession_hdr_t);
    plaintext_len = ciphertext_len - crypto_box_MACBYTES;
    plaintext = enif_make_new_binary(env, plaintext_len, &plaintext_term);

    if (crypto_box_open_easy_afternm(plaintext,
                                     ciphertext,
                                     ciphertext_len,
                                     header->session_nonce,
                                     box_key->key) != 0) {
        return atom_error;
    }

    return enif_make_tuple2(env, atom_ok, plaintext_term);
}

static ERL_NIF_TERM open_data_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary packet;
    ErlNifBinary session_key;
    const wblock_hdr_t *header;
    const unsigned char *ciphertext;
    unsigned long long ciphertext_len;
    unsigned long long plaintext_len = 0;
    ERL_NIF_TERM plaintext_term;
    unsigned char *plaintext;

    if (argc != 2) {
        return enif_make_badarg(env);
    }

    if (!inspect_binary(env, argv[0], &packet) ||
        !inspect_binary(env, argv[1], &session_key) ||
        session_key.size != crypto_aead_chacha20poly1305_KEYBYTES) {
        return enif_make_badarg(env);
    }

    if (packet.size < sizeof(wblock_hdr_t) + crypto_aead_chacha20poly1305_ABYTES) {
        return atom_error;
    }

    header = (const wblock_hdr_t *)packet.data;

    if (header->packet_type != WFB_PACKET_DATA) {
        return atom_error;
    }

    ciphertext = packet.data + sizeof(wblock_hdr_t);
    ciphertext_len = packet.size - sizeof(wblock_hdr_t);
    plaintext = enif_make_new_binary(env,
                                     ciphertext_len - crypto_aead_chacha20poly1305_ABYTES,
                                     &plaintext_term);

    if (crypto_aead_chacha20poly1305_decrypt(plaintext,
                                             &plaintext_len,
                                             NULL,
                                             ciphertext,
                                             ciphertext_len,
                                             packet.data,
                                             sizeof(wblock_hdr_t),
                                             header->data_nonce,
                                             session_key.data) != 0) {
        return atom_error;
    }

    if (plaintext_len + crypto_aead_chacha20poly1305_ABYTES != ciphertext_len) {
        return atom_error;
    }

    return enif_make_tuple2(env, atom_ok, plaintext_term);
}

static void write_be64(unsigned char *dst, uint64_t value) {
    dst[0] = (unsigned char)((value >> 56) & 0xFF);
    dst[1] = (unsigned char)((value >> 48) & 0xFF);
    dst[2] = (unsigned char)((value >> 40) & 0xFF);
    dst[3] = (unsigned char)((value >> 32) & 0xFF);
    dst[4] = (unsigned char)((value >> 24) & 0xFF);
    dst[5] = (unsigned char)((value >> 16) & 0xFF);
    dst[6] = (unsigned char)((value >> 8) & 0xFF);
    dst[7] = (unsigned char)(value & 0xFF);
}

static ERL_NIF_TERM seal_session_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary plaintext;
    ErlNifBinary session_nonce;
    ErlNifBinary rx_publickey;
    ErlNifBinary tx_secretkey;
    ERL_NIF_TERM packet_term;
    unsigned char *packet;
    unsigned long long ciphertext_len;

    if (argc != 4) {
        return enif_make_badarg(env);
    }

    if (!inspect_binary(env, argv[0], &plaintext) ||
        !inspect_binary(env, argv[1], &session_nonce) ||
        !inspect_binary(env, argv[2], &rx_publickey) ||
        !inspect_binary(env, argv[3], &tx_secretkey) ||
        session_nonce.size != crypto_box_NONCEBYTES ||
        rx_publickey.size != crypto_box_PUBLICKEYBYTES ||
        tx_secretkey.size != crypto_box_SECRETKEYBYTES) {
        return enif_make_badarg(env);
    }

    packet = enif_make_new_binary(env,
                                  sizeof(wsession_hdr_t) + plaintext.size + crypto_box_MACBYTES,
                                  &packet_term);

    packet[0] = WFB_PACKET_SESSION;
    memcpy(packet + 1, session_nonce.data, crypto_box_NONCEBYTES);

    if (crypto_box_easy(packet + sizeof(wsession_hdr_t),
                        plaintext.data,
                        plaintext.size,
                        session_nonce.data,
                        rx_publickey.data,
                        tx_secretkey.data) != 0) {
        return atom_error;
    }

    ciphertext_len = plaintext.size + crypto_box_MACBYTES;

    if (sizeof(wsession_hdr_t) + ciphertext_len !=
        sizeof(wsession_hdr_t) + plaintext.size + crypto_box_MACBYTES) {
        return atom_error;
    }

    return enif_make_tuple2(env, atom_ok, packet_term);
}

static ERL_NIF_TERM seal_data_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary plaintext;
    ErlNifUInt64 data_nonce;
    ErlNifBinary session_key;
    ERL_NIF_TERM packet_term;
    unsigned char *packet;
    unsigned long long ciphertext_len = 0;

    if (argc != 3) {
        return enif_make_badarg(env);
    }

    if (!inspect_binary(env, argv[0], &plaintext) ||
        !enif_get_uint64(env, argv[1], &data_nonce) ||
        !inspect_binary(env, argv[2], &session_key) ||
        session_key.size != crypto_aead_chacha20poly1305_KEYBYTES) {
        return enif_make_badarg(env);
    }

    packet = enif_make_new_binary(env,
                                  sizeof(wblock_hdr_t) + plaintext.size + crypto_aead_chacha20poly1305_ABYTES,
                                  &packet_term);

    packet[0] = WFB_PACKET_DATA;
    write_be64(packet + 1, (uint64_t)data_nonce);

    if (crypto_aead_chacha20poly1305_encrypt(packet + sizeof(wblock_hdr_t),
                                             &ciphertext_len,
                                             plaintext.data,
                                             plaintext.size,
                                             packet,
                                             sizeof(wblock_hdr_t),
                                             NULL,
                                             packet + 1,
                                             session_key.data) != 0) {
        return atom_error;
    }

    if (ciphertext_len != plaintext.size + crypto_aead_chacha20poly1305_ABYTES) {
        return atom_error;
    }

    return enif_make_tuple2(env, atom_ok, packet_term);
}

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
    int flags = ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER;

    (void)priv_data;
    (void)load_info;

    if (sodium_init() < 0) {
        return -1;
    }

    atom_ok = enif_make_atom(env, "ok");
    atom_error = enif_make_atom(env, "error");

    box_key_resource_type = enif_open_resource_type(env,
                                                    NULL,
                                                    "wfb_crypto_box_key",
                                                    NULL,
                                                    flags,
                                                    NULL);

    if (box_key_resource_type == NULL) {
        return -1;
    }

    return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"box_beforenm", 2, box_beforenm_nif, 0},
    {"open_session", 2, open_session_nif, 0},
    {"open_data", 2, open_data_nif, 0},
    {"seal_session", 4, seal_session_nif, 0},
    {"seal_data", 3, seal_data_nif, 0}
};

ERL_NIF_INIT(Elixir.NervesWifibroadcast.WFB.CryptoNif.Nif, nif_funcs, load, NULL, NULL, NULL)
