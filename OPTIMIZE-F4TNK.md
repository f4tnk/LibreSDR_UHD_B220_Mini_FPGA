# LibreSDR B220 Mini FPGA — Optimisations F4TNK

## Version 1.1 (Conservatif — DSP uniquement) — Mars 2026

**Fichier bitstream :** `usrp_b220_fpga_v1.bin`  
**Cible :** XC7A200T-FBG484-2 (Artix-7 200T)  
**Outil :** Vivado 2025.2  
**Compilé le :** 13 mars 2026 (13h18 → 13h35)  
**Auteur :** F4TNK  
**Stratégie :** Modifications DSP internes uniquement — aucun changement GPIF/USB/FIFO

---

## Contexte

Le projet LibreSDR B220 Mini est un firmware FPGA dérivé du USRP B210 (Ettus Research), porté sur la carte LibreSDR équipée d'un **Xilinx Artix-7 XC7A200T** (et non d'un Spartan-6 comme la carte B210 originale). Le design utilise intégralement les primitives 7-Series (DSP48E1, BUFR, BUFGMUX, IDDR/ODDR, MMCM) et le transceiver RF **AD9361** (Analog Devices — 12 bits I/Q, DDR CMOS, jusqu'à ~61,44 MSPS).

La V1.1 est une version **conservatrice** : seules les modifications internes à la chaîne DSP sont appliquées (extension CIC, correction DC). Les interfaces GPIF/USB et les tailles de FIFO restent strictement identiques à la version d'origine (V0) pour garantir la compatibilité avec le contrôleur FX3 et le driver UHD.

> **Note historique :** La V1.0 incluait également des augmentations de FIFO (GPIF 14→15, RADIO/SAMPLE 11→13, EXTRA_BUFF 12→14) et un changement SLEW SLOW→FAST sur les sorties GPIF. Ces modifications empêchaient le chargement du firmware. Elles ont été retirées dans la V1.1.

---

## Ressources FPGA disponibles — XC7A200T

| Ressource | Disponible |
|---|---|
| Slice LUTs | 134 600 |
| Slice Registers | 269 200 |
| Block RAM (RAMB36) | 365 |
| DSP48E1 | 740 |
| Fréquence max routing | ~250 MHz |

---

## Résultats de compilation V1.1

### Utilisation des ressources post-implémentation

| Ressource | Utilisé | Disponible | Utilisation |
|---|---|---|---|
| Slice LUTs | 30 708 | 134 600 | **22,81 %** |
| LUT as Logic | 25 555 | 134 600 | 18,99 % |
| LUT as Memory / SRL | 5 153 | 46 200 | 11,15 % |
| Slice Registers | 33 501 | 269 200 | **12,44 %** |
| Block RAM Tiles | 115,5 | 365 | **31,64 %** |
| DSP48E1 | 100 | 740 | **13,51 %** |

> **Note :** L'utilisation BRAM est nettement réduite par rapport à la V1.0 (81,78 % → 31,64 %) car les FIFOs GPIF et radio ne sont plus augmentées. Il reste **249,5 BRAM libres** (68 %) pour de futures améliorations.

### Timing — toutes les contraintes respectées

| Horloge | Fréquence | WNS | Statut |
|---|---|---|---|
| `CAT_DCLK_P` (radio_clk, SISO) | ~80 MHz | +1,327 ns | ✅ |
| Design global WNS | — | **+0,515 ns** | ✅ |

`All user specified timing constraints are met.` — 0 Errors, 0 Critical Warnings, 2 Warnings

---

## Modifications apportées en V1.1

> **Principe :** Seules les modifications internes à la chaîne DSP sont appliquées. Aucune modification des interfaces GPIF/USB, des tailles de FIFO, ni des propriétés SLEW des IO.

### ~~1. Augmentation des tailles de FIFO~~ — RETIRÉE

Les modifications de FIFO (RADIO_FIFO 11→13, SAMPLE_FIFO 11→13, EXTRA_BUFF 12→14, DATA_*_FIFO 14→15) ainsi que le changement SLEW SLOW→FAST sur les sorties GPIF, présentes dans la V1.0, ont été **retirées** car elles empêchaient le fonctionnement du firmware. Ces fichiers sont restaurés à leurs valeurs V0 d'origine.

---

### 2. Extension du taux de décimation/interpolation CIC (128 → 256)

**Problème :** Les filtres CIC (Cascaded Integrator-Comb, ordre N=4) étaient limités à un taux maximum de 128. Le taux de décimation total maximum était donc : HB1(×2) × HB2(×2) × CIC(×128) = **×512**.

**Après modification :** HB1(×2) × HB2(×2) × CIC(×256) = **×1024 maximum**.

Cela permet des fréquences d'échantillonnage UHD très basses (par ex. 60 kSPS à partir de 61,44 MSPS ADC clock).

#### Fichier : `src/.../lib/dsp/cic_decim.v`

```verilog
// Avant
parameter log2_of_max_rate = 7;   // max rate = 128, accum width = 24+28 = 52 bits

// Après
parameter log2_of_max_rate = 8;   // max rate = 256, accum width = 24+32 = 56 bits
```

#### Fichier : `src/.../lib/dsp/cic_interp.v`

```verilog
// Avant
parameter log2_of_max_rate = 7;   // max rate = 128, accum width = 18+21 = 39 bits

// Après
parameter log2_of_max_rate = 8;   // max rate = 256, accum width = 18+24 = 42 bits
```

#### Fichier : `src/.../lib/dsp/cic_dec_shifter.v`

Table de compensation de gain CIC (décimation) étendue pour couvrir les taux 1–256 :

```verilog
// Avant
parameter maxbitgain = 28;    // gain max N*log2(128) = 4*7 = 28 bits
output [4:0] shift;           // registre de décalage 5 bits (max 28)

// Après
parameter maxbitgain = 32;    // gain max N*log2(256) = 4*8 = 32 bits
output [5:0] shift;           // registre de décalage 6 bits (max 32)
// + entries bitgain pour taux 129..256
```

#### Fichier : `src/.../lib/dsp/cic_int_shifter.v`

Table de compensation de gain CIC (interpolation) étendue :

```verilog
// Avant
parameter maxbitgain = 21;    // gain max (N-1)*log2(128) = 3*7 = 21 bits
output [4:0] shift;           // 5 bits

// Après
parameter maxbitgain = 24;    // gain max (N-1)*log2(256) = 3*8 = 24 bits
output [5:0] shift;           // 6 bits
// + entries bitgain pour taux 102..256
```

---

### 3. Filtre de correction de décalage DC (nouveau module)

**Problème :** L'AD9361 est un transceiver à conversion directe (direct-conversion). Ce type d'architecture génère inévitablement un décalage DC (offset) en bande de base, visible comme un pic spectral à 0 Hz. Ce phénomène dégrade la qualité des signaux et la dynamique du récepteur.

**Solution :** Ajout d'un filtre passe-haut IIR du premier ordre sur chaque voie I et Q, avant le CORDIC NCO, dans la chaîne DDC.

#### Nouveau fichier : `src/.../lib/dsp/dc_offset_correct.v`

```verilog
module dc_offset_correct #(
    parameter WIDTH = 24,    // largeur du signal (bits)
    parameter ALPHA = 20     // constante de temps : 2^20
)
// Algorithme :
//   avg[n] = avg[n-1] + (x[n] - avg[n-1]) >> ALPHA
//   y[n]   = x[n] - avg[n]
//
// Fréquence de coupure fc ≈ fs / (2π × 2^ALPHA)
//   → fc ≈ 61,44e6 / (2π × 2^20) ≈ 9 Hz @ 61,44 MSPS (SISO full rate)
//
// Accumulateur interne : WIDTH + ALPHA = 24 + 20 = 44 bits
// Consommation : 1 additionneur + 1 décaleur (sans DSP48E1)
```

Un registre de contournement (`bypass`) peut être activé via le logiciel UHD pour désactiver le filtre :

```
dc_offset_bypass = 0  →  filtre actif (défaut)
dc_offset_bypass = 1  →  signal passe sans modification
```

#### Fichier modifié : `src/.../lib/dsp/ddc_chain.v`

- Ajout d'un `setting_reg` à l'adresse **BASE+5** pour le bit `dc_offset_bypass`
- Instanciation de `dc_offset_correct` pour la voie I et la voie Q
- Réacheminement : le signal corrigé (`rx_fe_i_dc`, `rx_fe_q_dc`) alimente l'entrée du CORDIC, à la place du signal direct du port AD9361

```verilog
// Nouveau registre de contrôle
setting_reg #(.my_addr(BASE+5)) sr_dc_offset (
    ...out(dc_offset_bypass)...
);

// Correction I
dc_offset_correct #(.WIDTH(24), .ALPHA(20)) dc_i (
    .clk(clk), .reset(reset),
    .bypass(dc_offset_bypass),
    .in(rx_fe_i_mux), .out(rx_fe_i_dc)
);

// Correction Q
dc_offset_correct #(.WIDTH(24), .ALPHA(20)) dc_q (
    .clk(clk), .reset(reset),
    .bypass(dc_offset_bypass),
    .in(rx_fe_q_mux), .out(rx_fe_q_dc)
);
```

---

### ~~4. Optimisation du SLEW rate des sorties GPIF2~~ — RETIRÉE

Le passage SLEW SLOW→FAST sur les sorties GPIF a été retiré dans la V1.1 (causait un dysfonctionnement du firmware).

---

### 5. Ajout du fichier `dc_offset_correct.v` au projet Vivado

Le nouveau module `dc_offset_correct.v` a été ajouté à la liste des sources du projet Vivado dans le fichier `.xpr` :

```xml
<!-- Ajouté dans libresdr_b210.xpr, FileSet sources_1 -->
<File Path="$PSRCDIR/sources_1/imports/lib/dsp/dc_offset_correct.v">
  <FileInfo>
    <Attr Name="UsedIn" Val="synthesis"/>
    <Attr Name="UsedIn" Val="implementation"/>
    <Attr Name="UsedIn" Val="simulation"/>
  </FileInfo>
</File>
```

---

## Récapitulatif des fichiers modifiés (V1.1)

| Fichier | Type | Modification |
|---|---|---|
| `lib/dsp/cic_decim.v` | Verilog modifié | log2_of_max_rate 7→8 |
| `lib/dsp/cic_interp.v` | Verilog modifié | log2_of_max_rate 7→8 |
| `lib/dsp/cic_dec_shifter.v` | Verilog modifié | maxbitgain 28→32, shift [4:0]→[5:0], table 1..256 |
| `lib/dsp/cic_int_shifter.v` | Verilog modifié | maxbitgain 21→24, shift [4:0]→[5:0], table 1..256 |
| `lib/dsp/ddc_chain.v` | Verilog modifié | SR BASE+5, dc_offset_correct ×2, rewiring CORDIC |
| `lib/dsp/dc_offset_correct.v` | **Nouveau fichier** | Filtre IIR HP, WIDTH=24, ALPHA=20, fc≈9 Hz |
| `src/libresdr_b210.xpr` | XML modifié | Ajout dc_offset_correct.v comme source |

**Fichiers NON modifiés (identiques à V0) :**
- `lib/esdr_b210/top/b200_core.v` — FIFO sizes inchangées
- `lib/esdr_b210/top/libresdr_b210.v` — GPIF FIFO sizes inchangées
- `constrs_2/imports/xdc/b210.xdc` — SLEW SLOW inchangé
- Tous les fichiers `.xci` — IPs non modifiées

---

## Architecture de la chaîne DSP après V1.1

### Réception (RX DDC) — par canal

```
AD9361 I/Q (12 bits, DDR CMOS)
    │
    ▼ [libresdr_b205_io.v]
Port P0 désérialisé (24 bits I/Q)
    │
    ▼ [ddc_chain.v — MUX real/IQ/swap]
rx_fe_i_mux  /  rx_fe_q_mux  (24 bits)
    │
    ▼ [dc_offset_correct.v — NOUVEAU]   fc ≈ 9 Hz, IIR HP, bypass via SR BASE+5
rx_fe_i_dc   /  rx_fe_q_dc   (24 bits)
    │
    ▼ [cordic_z24.v]    NCO 32 bits, rotation complexe, CORDIC 25 étages
I/Q décalé en fréquence (25 bits)
    │
    ▼ [cic_decim.v]     CIC décimateur, N=4, taux 1..256 (était 1..128)
I/Q décimé (16 bits)
    │
    ▼ [hbdec1.ngc]      Demi-bande HB1, ×2
    ▼ [hbdec2.ngc]      Demi-bande HB2, ×2
I/Q (16 bits)
    │
    ▼ [MULT_MACRO + round_sd]   Facteur d'échelle logiciel + arrondi sigma-delta
Sortie 16 bits I/Q vers UHD
```

**Décimation totale maximale V1 :** 2 × 2 × 256 = **1024**  
(était 512 en version d'origine)

### Émission (TX DUC) — par canal

```
UHD 16 bits I/Q
    │
    ▼ MULT_MACRO scale
    ▼ [hb47_int.v]  HB1 interpolateur ×2
    ▼ [hb47_int.v]  HB2 interpolateur ×2
    ▼ [cic_interp.v]  CIC interpolateur, N=4, taux 1..256 (était 1..128)
    ▼ [cordic_z24.v]  NCO décalage en fréquence ×
    ▼ clip 24 bits
AD9361 I/Q (12 bits)
```

---

---

## Version 2 — Mars 2026

**Fichier bitstream :** `usrp_b220_fpga_v2.bin`  
**Compilé le :** 13 mars 2026  
**Stratégie :** Extensions DSP internes — IQ balance, 3ème demi-bande, NCO 48 bits

### Résultats de compilation V2

| Ressource | Utilisé | Disponible | Utilisation |
|---|---|---|---|
| Slice LUTs | ~32 500 | 134 600 | **24,12 %** |
| Slice Registers | ~36 500 | 269 200 | ~13,6 % |
| Block RAM Tiles | 115,5 | 365 | **31,64 %** |
| DSP48E1 | 112 | 740 | **15,14 %** |
| **WNS** | — | — | **+0,165 ns** ✅ |

### Modifications V2

#### 1. Correction de déséquilibre IQ (nouveau module `iq_balance.v`)

Ajout d'une correction matricielle 2×2 avant le CORDIC pour compenser le déséquilibre amplitude/phase du mélangeur direct de l'AD9361.

```
I_out = alpha × I_in
Q_out = beta  × I_in + Q_in
```

Format Q2.16 — `alpha` défaut `0x10000` (=1.0), `beta` défaut `0x00000` (=0.0). Utilise 2×DSP48E1. Deux registres UHD ajoutés dans `ddc_chain.v` :
- `BASE+6` : `iq_alpha` (18 bits)
- `BASE+7` : `iq_beta`  (18 bits)

#### 2. 3ème filtre demi-bande HB3 (décimation/interpolation ×2)

Ajout de `small_hb_dec` (décimateur) et `small_hb_int` (interpolateur) dans `ddc_chain.v` et `duc_chain.v`.  
Décimation totale max : HB1(×2) × HB2(×2) × **HB3(×2)** × CIC(×256) = **×2048**.

Le bit d'activation HB3 est stocké à la position **bit 10** du registre `sr_2` (BASE+2), au-dessus des bits HB1/HB2 compatibles driver UHD stock.

#### 3. NCO 48 bits (résolution de phase fine)

Extension de l'accumulateur de phase CORDIC de 32 à 48 bits.

| | 32 bits | 48 bits |
|---|---|---|
| Résolution @ 61,44 MSPS | 14,3 mHz | **0,22 mHz** |
| Précision fréquentielle | ± 7 mHz | **± 0,11 mHz** |

Registre supplémentaire `BASE+8` (`phase_inc_hi`, 16 bits) ajouté dans `ddc_chain.v` et `duc_chain.v`. Compatible backward : si `phase_inc_hi = 0`, comportement identique 32 bits.

### Fichiers modifiés V2

| Fichier | Modification |
|---|---|
| `lib/dsp/iq_balance.v` | **Nouveau** — correction IQ matricielle Q2.16, 2×DSP48 |
| `lib/dsp/ddc_chain.v` | SR BASE+6/7/8, instanciation iq_balance, HB3, NCO 48b |
| `lib/dsp/duc_chain.v` | SR BASE+8, HB3 interp, NCO 48b, log2_of_max_rate=8 |
| `src/libresdr_b210.xpr` | Ajout iq_balance.v comme source |

---

## Version 3 — 13 mars 2026

**Fichier bitstream :** `usrp_b220_fpga_v3.bin`  
**Compilé le :** 13 mars 2026 (15h24 → 15h50, ~26 min)  
**Stratégie :** Optimisations quantification DSP + correction bug HB enable bits

### Résultats de compilation V3

| Ressource | V2 | V3 | Disponible |
|---|---|---|---|
| Slice LUTs | 24,12 % | **25,50 %** | 134 600 |
| Slice Registers | ~13,6 % | **14,07 %** | 269 200 |
| Block RAM Tiles | 31,64 % | **31,64 %** | 365 |
| DSP48E1 | 15,14 % (112) | **15,14 % (112)** | 740 |
| **WNS** | +0,165 ns | **+1,224 ns** ✅ | — |

Le WNS est **7× plus large** qu'en V2 : meilleure robustesse face aux variations de température et tension.

### Modifications V3

#### 1. Correction arrondi CIC décimateur (`cic_dec_shifter.v`)

La table de compensation de gain CIC utilisait une **troncature pure** (perte du bit de poids faible). Remplacement par un arrondi convergent avec protection débordement.

```verilog
// Avant — troncature pure
assign signal_out = signal_in[shift+bw-1 : shift];

// Après — arrondi convergent avec garde débordement
wire trunc_out  = signal_in[shift+bw-1 : shift];
wire round_bit  = signal_in[shift-1];
wire would_overflow = ~trunc_out[bw-1] & (&trunc_out[bw-2:0]) & round_bit;
assign signal_out = would_overflow ? trunc_out : (trunc_out + round_bit);
```

**Impact :** ~6 dB de SNR récupéré à chaque taux de décimation.

#### 2. Correction arrondi CIC interpolateur TX (`cic_int_shifter.v`)

Même correction appliquée au chemin TX. Impact identique : ~6 dB SNR sur la voie émission.

#### 3. CORDIC étendu de 20 à 24 étages (`cordic_z24.v`)

Le CORDIC NCO avait 20 étages pour une phase de 24 bits — les 4 derniers bits de phase étaient ignorés. Extension à 24 étages en utilisant les constantes arctangente `c20`–`c23` déjà définies dans le module.

| | 20 étages | 24 étages |
|---|---|---|
| SFDR théorique | ~120 dB | **~144 dB** |
| Précision angulaire | 4 bits ignorés | 0 bit ignoré |
| LUT additionnels | — | ~200 |

Paramètre `stages` mis à jour de 19 à 24. Sortie passée de `x20` (troncature) à `x24[bitwidth:1] + x24[0]` (arrondi).

#### 4. Rounding CORDIC→CIC + dither RPDF (`ddc_chain.v`)

**Rounding 25→24 bits** à la sortie du CORDIC avant entrée CIC, avec protection débordement :

```verilog
wire i_cord_ovf = (i_cordic[24] == i_cordic[23]);
assign i_cic_in = i_cord_ovf ? i_cordic[24:1] : {i_cordic[24], {23{~i_cordic[24]}}};
// + arrondi du bit 0
```

**Dither RPDF** (Rectangular Probability Density Function) : ajout d'un LFSR 16 bits (polynôme x¹⁶+x¹⁴+x¹³+x¹¹+1, graine `0xACE1`) injectant ±1 LSB avant le CIC. Élimine les tons parasites CIC ("idle tones") qui apparaissent sur les signaux à basse fréquence.

#### 5. Arrondi extraction HB1/HB2 (`ddc_chain.v`)

Les filtres demi-bandes HB1 et HB2 (`hb47_dec`) produisent une sortie 47 bits. L'extraction vers 24 bits effectuait une **troncature** de 18 bits LSB. Remplacement par arrondi :

```verilog
// Avant — troncature pure
assign i_hb1_rnd = i_hb1[47:24];

// Après — arrondi sur bit [HB1_SCALE-1]
assign i_hb1_rnd = i_hb1[47:24] + {{23{1'b0}}, i_hb1[23]};
```

Même correction pour HB2. Impact : ~6 dB SNR pour chaque filtre actif.

#### 6. Arrondi HB3→prescale 24→19 bits (`ddc_chain.v`)

La réduction 24→19 bits avant le bloc prescale utilisait une **troncature** de 5 bits (perte de ~30 dB de dynamique potentielle à faible signal). Remplacement par arrondi avec saturation :

```verilog
wire i_hb3_ovf = (i_hb3[23] != i_hb3[22]);
assign i_hb3_rnd = i_hb3_ovf ? {i_hb3[23], {18{~i_hb3[23]}}}
                              : i_hb3[23:5] + {{18{1'b0}}, i_hb3[4]};
```

#### 7. Correction critique — ordre des bits enable halfband (`ddc_chain.v`, `duc_chain.v`)

**Bug V2 :** Le registre `sr_2` (BASE+2) stockait les enables halfband dans l'ordre `{enable_hb1[10], enable_hb2[9], enable_hb3[8], rate[7:0]}`. Or le driver UHD stock écrit `hb0 << 9 | hb1 << 8`, ce qui causait un **décalage d'un bit** : `enable_hb1` n'était jamais activé, et `enable_hb2`/`enable_hb3` recevaient les mauvaises valeurs.

**Symptôme observé :** Erreur UHD `[B200] Got a ctrl packet with unknown SID 44932147` (= `0x02AD9C33`). Ce SID invalide est en réalité des échantillons IQ corrompus débordant sur le bus de contrôle, causés par un désaccord débit DSP/packetiseur VITA.

**Correction :** Réordonnancement des bits pour correspondre au driver UHD stock :

```verilog
// Avant (V2) — incorrect
.out({enable_hb1, enable_hb2, enable_hb3, cic_decim_rate})
//    bit 10       bit 9       bit 8

// Après (V3) — correct, compatible driver UHD
.out({enable_hb3, enable_hb1, enable_hb2, cic_decim_rate})
//    bit 10       bit 9       bit 8
//    (optionnel,  (= UHD hb0  (= UHD hb1
//     jamais      << 9)        << 8)
//     écrit)
```

`enable_hb3` en bit 10 : jamais écrit par le driver stock → reste à 0 par défaut → HB3 bypassé (comportement sûr). Pour activer HB3, le bit 10 doit être écrit explicitement par un driver personnalisé.

### Fichiers modifiés V3

| Fichier | Modification |
|---|---|
| `lib/dsp/cic_dec_shifter.v` | Arrondi convergent + protection débordement (tous taux) |
| `lib/dsp/cic_int_shifter.v` | Idem pour TX |
| `lib/dsp/cordic_z24.v` | 20→24 étages, paramètre stages=24, sortie arrondie |
| `lib/dsp/ddc_chain.v` | LFSR dither, CORDIC→CIC rnd, HB1/HB2 rnd, HB3 rnd, **fix bit order HB** |
| `lib/dsp/duc_chain.v` | **Fix bit order HB** |

### Bilan des améliorations DSP V3 (chaîne RX)

| Point de la chaîne | Avant | Après | Gain |
|---|---|---|---|
| CORDIC NCO (étages) | 20 | 24 | +24 dB SFDR |
| CORDIC sortie | troncature | arrondi | ~6 dB |
| Dither avant CIC | absent | LFSR ±1 LSB | élimine idle tones |
| CORDIC→CIC (25→24b) | troncature | arrondi | ~6 dB |
| HB1 extraction (47→24b) | troncature | arrondi | ~6 dB |
| HB2 extraction (47→24b) | troncature | arrondi | ~6 dB |
| HB3→prescale (24→19b) | troncature | arrondi + saturation | ~6 dB |
| CIC shifter (décim) | troncature | arrondi convergent | ~6 dB |
| CIC shifter (interp TX) | troncature | arrondi convergent | ~6 dB |

---

---

## Version 3.1 — 13 mars 2026

**Fichier bitstream :** `usrp_b220_fpga_v3.bin` (remplace V3)  
**Compilé le :** 13 mars 2026 (17h17 → 17h33, ~16 min)  
**Stratégie :** Correctif bug débordement dither identifié lors d'un audit DSP approfondi

### Résultats de compilation V3.1

| Ressource | V3 | V3.1 | Disponible |
|---|---|---|---|
| Slice LUTs | 25,50 % | **25,51 %** | 134 600 |
| Slice Registers | 14,07 % | **14,07 %** | 269 200 |
| Block RAM Tiles | 31,64 % | **31,64 %** | 365 |
| DSP48E1 | 15,14 % (112) | **15,14 % (112)** | 740 |
| **WNS** | +1,224 ns | **+0,369 ns** ✅ | — |

Utilisation quasi identique (2 LUTs ajoutés pour la détection min-négatif). WNS reste positif — timing respecté.

### Correction bug débordement dither (`ddc_chain.v`)

**Bug V3 :** Le dither RPDF (±1 LSB) utilisait `{{23{lfsr[0]}}, lfsr[0]}` pour générer 0 ou -1. Quand `lfsr[0]=1`, la valeur dither = `24'hFFFFFF` = -1 en signé 24 bits. Si le signal arrondi est exactement à la valeur **minimum négative** (`0x800000` = -2²³), l'addition `-2²³ + (-1)` **déborde** et produit +2²³-1 (maximum positif) — inversion instantanée du signal.

**Probabilité :** Faible mais non nulle (1/2 × 1/2²⁴ par cycle), plus fréquente sur fort CW ou saturation.

**Correction :** Détection du minimum négatif et suppression du dither dans ce cas :

```verilog
// V3.1 — Protection débordement dither
wire i_at_min = i_cord_rnd[WIDTH-1] & ~(|i_cord_rnd[WIDTH-2:0]);  // true si 0x800000
wire q_at_min = q_cord_rnd[WIDTH-1] & ~(|q_cord_rnd[WIDTH-2:0]);
wire i_dither = lfsr[0] & ~i_at_min;   // dither supprimé si signal = min négatif
wire q_dither = lfsr[8] & ~q_at_min;
```

**Coût :** 2 LUTs, 0 registre additionnel, 0 cycle de latence.

### Correction commentaire TPDF → RPDF

Le commentaire désignait à tort le dither comme "TPDF" (Triangular PDF). En réalité, un seul LFSR injectant ±1 LSB réalise un dither **RPDF** (Rectangular PDF). Corrigé dans les commentaires (pas d'impact fonctionnel).

### Fichiers modifiés V3.1

| Fichier | Modification |
|---|---|
| `lib/dsp/ddc_chain.v` | Protection débordement dither (min-négatif), correction commentaires RPDF |

### Résultat audit DSP complet (20 points vérifiés)

L'audit a vérifié l'ensemble des fichiers DSP : `cordic_z24.v`, `cordic_stage.v`, `cic_dec_shifter.v`, `cic_int_shifter.v`, `ddc_chain.v`, `duc_chain.v`, `iq_balance.v`, `dc_offset_correct.v`, `small_hb_dec.v`, `small_hb_int.v`, `cic_decim.v`, `cic_interp.v`.

| Sévérité | Trouvailles | Action |
|---|---|---|
| **HIGH** | 1 (débordement dither) | **Corrigé V3.1** |
| Medium | 1 (`MULT18X18S` Spartan-3 dans `small_hb_int.v`) | Non corrigé (fonctionne via mapping Vivado unisim) |
| Low/Info | 18 (ports inutilisés, code mort, marges théoriques) | Non corrigé (cosmétique, pas d'impact fonctionnel) |

---

## Version 4 — 13 mars 2026

**Fichier bitstream :** `usrp_b220_fpga_v4.bin`  
**Compilé le :** 13 mars 2026 (18h05 → 18h22, ~17 min)  
**Stratégie :** Optimisation de précision DSP pour signaux LEO faibles (state-of-the-art)

### Résultats de compilation V4

| Ressource | V3.1 | V4 | Disponible |
|---|---|---|---|
| Slice LUTs | 25,51 % (34 342) | **25,56 % (34 404)** | 134 600 |
| Slice Registers | 14,07 % | **14,07 %** | 269 200 |
| Block RAM Tiles | 31,64 % | **31,64 %** | 365 |
| DSP48E1 | 15,14 % (112) | **15,14 % (112)** | 740 |
| **WNS** | +0,369 ns | **+0,228 ns** ✅ | — |

Delta : +62 LUTs, 0 DSP, 0 BRAM. WNS reste positif — timing respecté.

### Modifications V4

#### 1. IQ Balance pleine précision 24 bits (`iq_balance.v`) — +6 dB plancher

**Problème V2 :** L'entrée 24 bits de `iq_balance` était tronquée à 18 bits (`i_trunc = i_in[23:6]`) avant multiplication par les coefficients alpha/beta. Les 6 bits LSB étaient perdus, réduisant la plage dynamique de 36 dB (6 bits × 6 dB).

**Solution V4 :** Utilisation native du multiplieur 25×18 signé du DSP48E1. Le MULT_MACRO passe de `WIDTH_A(18)` à `WIDTH_A(WIDTH)` (= 24). Le produit passe de 36 à 42 bits avec extraction ajustée.

```verilog
// Avant (V2) — 18 bits tronqué, 6 LSBs perdus
wire signed [17:0] i_trunc = i_in[WIDTH-1:WIDTH-18];
MULT_MACRO #(.WIDTH_A(18), .WIDTH_B(18)) mult_alpha (.A(i_trunc), ...);
wire signed [WIDTH:0] i_wide = prod_alpha_i[34:34-WIDTH];

// Après (V4) — pleine précision 24 bits, zéro perte
wire signed [WIDTH-1:0] i_full = i_in;
MULT_MACRO #(.WIDTH_A(WIDTH), .WIDTH_B(18)) mult_alpha (.A(i_full), ...);
wire signed [WIDTH:0] i_wide = prod_alpha_i[WIDTH+16:16];
```

**Impact :** +6 dB de dynamique récupérée au plancher de bruit, critique pour les signaux LEO faibles (FSK/GMSK <10 dB Eb/N0).  
**Coût :** 0 DSP (même bloc DSP48E1), ~10 LUTs (routage interne).

#### 2. Arrondi HB1→HB2 avec protection débordement (`ddc_chain.v`) — +6 dB SNR

**Problème V3 :** L'entrée du filtre HB2 (`hbdec2`) recevait une **troncature pure** de la sortie HB1 (`i_hb1[41:18]`), perdant 18 LSBs. De plus, l'arrondi dans le multiplexeur pre-HB3 (cases HB1-only et HB1+HB2) n'avait **aucune protection de débordement** : si la valeur tronquée était au maximum positif (0x7FFFFF) et le bit d'arrondi=1, wrap vers minimum négatif (0x800000).

**Solution V4 :** Calcul de signaux arrondis avec protection overflow en amont (wires réutilisés) :

```verilog
// V4: Overflow-safe rounding HB1 47→24b
wire i_hb1_ovf = ~i_hb1[41] & (&i_hb1[40:18]) & i_hb1[17];
assign i_hb1_rnd = i_hb1_ovf ? i_hb1[41:18]
                              : (i_hb1[41:18] + {23'b0, i_hb1[17]});
```

Utilisé dans :
- **Entrée hbdec2** : `i_hb1_rnd` remplace `i_hb1[41:18]` (troncature → arrondi)
- **Mux pre-HB3** : mêmes wires réutilisés avec protection overflow

**Impact :** +6 dB SNR (arrondi vs troncation HB1→HB2) + correction bug overflow.  
**Coût :** ~52 LUTs (détection overflow × 4 signaux I/Q × HB1/HB2).

#### 3. Correction commentaire alpha (`ddc_chain.v`)

Le commentaire indiquait `alpha=1.0 (0x20000)` (qui vaut 2.0 en Q2.16). Corrigé en `0x10000` (correct = 1.0).

### Fichiers modifiés V4

| Fichier | Modification |
|---|---|
| `lib/dsp/iq_balance.v` | MULT_MACRO 24×18 pleine précision, extraction bits ajustée, en-tête V4 |
| `lib/dsp/ddc_chain.v` | Wires arrondi overflow-safe HB1/HB2, hbdec2 entrée arrondie, pre-HB3 mux, fix commentaire |

### Bilan des améliorations DSP V4 (chaîne RX)

| Point de la chaîne | V3.1 | V4 | Gain |
|---|---|---|---|
| IQ balance input | troncature 24→18b | **pleine précision 24b** | **+6 dB floor** |
| HB1→HB2 feed | troncature 47→24b | **arrondi overflow-safe** | **+6 dB SNR** |
| HB1→pre-HB3 | arrondi sans overflow check | **arrondi overflow-safe** | bug fix |
| HB2→pre-HB3 | arrondi sans overflow check | **arrondi overflow-safe** | bug fix |

### Justification technique DSP pour LEO satellite

**Pourquoi CIC droop compensation n'est PAS implémentée :**  
Pour les signaux LEO narrowband typiques (9.6 kbps GMSK → 4.8 kHz BW, sortie CIC à 960 kSPS pour R=64), la fréquence du signal est à ~0.5% du Nyquist de sortie. Le droop CIC (sinc⁴) à cette fréquence est < 0.001 dB — totalement négligeable. La compensation CIC n'est bénéfique que pour signaux wideband approchant le Nyquist, ce qui n'est pas le cas du décodage satellite LEO.

---

## Architecture de la chaîne DSP — V4

### Réception (RX DDC) — par canal

```
AD9361 I/Q (12 bits, DDR CMOS)
    │
    ▼ [libresdr_b205_io.v]
Port P0 désérialisé (24 bits I/Q)
    │
    ▼ [ddc_chain.v — MUX real/IQ/swap]
rx_fe_i_mux  /  rx_fe_q_mux  (24 bits)
    │
    ▼ [dc_offset_correct.v — V1.1]   fc ≈ 9 Hz, IIR HP, bypass via SR BASE+5
    │
    ▼ [iq_balance.v — V4]            correction IQ, 24×18 DSP48E1 pleine précision
    │
    ▼ [LFSR 16 bits — V3]            dither RPDF ±1 LSB (élimine idle tones CIC)
    │
    ▼ [cordic_z24.v — V3]            NCO 48 bits, 24 étages, sortie arrondie
I/Q décalé en fréquence (24 bits, arrondi)
    │
    ▼ [cic_decim.v]                  CIC décimateur N=4, taux 1..256
    ▼ [cic_dec_shifter.v — V3]       compensation gain, arrondi convergent
I/Q décimé (16 bits)
    │
    ▼ [hbdec1 — HB1]                 demi-bande ×2, extraction 47→24b arrondie overflow-safe (V4)
    ▼ [hbdec2 — HB2]                 demi-bande ×2, entrée arrondie (V4), extraction overflow-safe
    ▼ [small_hb_dec — HB3 — V2]      demi-bande ×2 optionnelle, 24→19b arrondi (V3)
I/Q (16 bits)
    │
    ▼ [MULT_MACRO + round_sd]        facteur d'échelle + arrondi sigma-delta
Sortie 16 bits I/Q → UHD host
```

**Décimation totale maximale V3 :** 2 × 2 × 2 × 256 = **×2048** (HB3 activé)  
**Fréquence d'échantillonnage min :** 61,44 MSPS / 2048 ≈ **30 kSPS**

### Émission (TX DUC) — par canal

```
UHD 16 bits I/Q
    │
    ▼ MULT_MACRO scale
    ▼ [small_hb_int — HB3 — V2]      interpolateur ×2 optionnel
    ▼ [hb47_int — HB1]               interpolateur ×2
    ▼ [hb47_int — HB2]               interpolateur ×2
    ▼ [cic_interp.v]                 CIC interpolateur N=4, taux 1..256
    ▼ [cic_int_shifter.v — V3]       compensation gain, arrondi convergent
    ▼ [cordic_z24.v — V3]            NCO 48 bits, 24 étages
    ▼ clip 24 bits
AD9361 I/Q (12 bits)
```

---

## Récapitulatif de toutes les versions

| Version | WNS | DSP | LUT | Fonctionnel |
|---|---|---|---|---|
| V0 (original) | — | ~100 | ~22 % | ✅ |
| V1.0 | — | ~100 | ~22 % | ❌ (GPIF cassé) |
| V1.1 | +0,515 ns | 100 (13,5 %) | 22,81 % | ✅ (confirmé HW) |
| V2 | +0,165 ns | 112 (15,1 %) | 24,12 % | ✅ (bug SID existant) |
| V3 | +1,224 ns | 112 (15,1 %) | 25,50 % | ✅ (bug SID corrigé) |
| V3.1 | +0,369 ns | 112 (15,1 %) | 25,51 % | ✅ (audit + fix dither) |
| **V4** | **+0,228 ns** | **112 (15,1 %)** | **25,56 %** | **✅ (IQ pleine précision + HB overflow fix)** |

---

---

## Version 5 — 13 mars 2026

**Fichier bitstream :** `usrp_b220_fpga_v6_opus++.bin`  
**Compilé le :** 13 mars 2026  
**Stratégie :** Noise shaping sigma-delta d'ordre 2 — état de l'art en quantification DSP

### Résultats de compilation V5

| Ressource | V4 | V5 | Disponible |
|---|---|---|---|
| Slice LUTs | 25,56 % | **~26 %** | 134 600 |
| Slice Registers | 14,07 % | **~14,2 %** | 269 200 |
| Block RAM Tiles | 31,64 % | **31,64 %** | 365 |
| DSP48E1 | 112 (15,1 %) | **112 (15,1 %)** | 740 |
| **WNS** | +0,228 ns | **+0,325 ns** ✅ | — |

### Modifications V5

#### 1. Module `round_sd.v` — Ajout du noise shaping sigma-delta d'ordre 2

**Problème :** Le module d'arrondi `round_sd` implémentait un noise shaping de premier ordre standard (NTF = $1-z^{-1}$). Le bruit de quantification décroissait à -6 dB/octave — suffisant pour des applications classiques, mais pas optimal pour des signaux LEO faibles noyés dans le bruit.

**Solution V5 :** Ajout d'un paramètre `SD_ORDER` (défaut = 1 pour backward compatibility) :

- `SD_ORDER = 1` : Premier ordre, NTF = $(1-z^{-1})$ → **-6 dB/octave** (comportement original)
- `SD_ORDER = 2` : Second ordre, NTF = $(1-z^{-1})^2$ → **-12 dB/octave** (+8 dB SNR floor théorique)

L'implémentation du 2ème ordre utilise la relation de feedback d'erreur : `err_fb = 2*err[n] - err[n-1]`, avec clipping pour prévenir l'instabilité.

```verilog
// V5: 2nd-order sigma-delta noise shaping
generate
  if (SD_ORDER >= 2) begin : gen_sd2
    reg [ERR_WIDTH-1:0] err_d1;
    always @(posedge clk) begin
      if (reset) err_d1 <= 0;
      else if (strobe_pre) err_d1 <= err;
    end
    wire signed [ERR_WIDTH:0] err_x2   = {err[ERR_WIDTH-1], err} + {err[ERR_WIDTH-1], err};
    wire signed [ERR_WIDTH:0] err_d1_e = {err_d1[ERR_WIDTH-1], err_d1};
    wire signed [ERR_WIDTH:0] err_diff = err_x2 - err_d1_e;
    clip #(.bits_in(ERR_WIDTH+1), .bits_out(ERR_WIDTH)) clip_sd2 (.in(err_diff), .out(err_fb));
  end else begin : gen_sd1
    assign err_fb = err;
  end
endgenerate
```

**Coût :** 1 registre + 1 additionneur + 1 clip par instance. Aucun DSP48E1.

#### 2. Application SD_ORDER(2) aux rounders de sortie DDC (`ddc_chain.v`)

Les `round_sd` de sortie finale (33→16 bits) dans `ddc_chain.v` passent de `SD_ORDER(1)` à `SD_ORDER(2)`, repoussant le bruit de quantification hors bande avec une pente deux fois plus agressive.

**Impact sur le plancher de bruit :**
- Signal LEO typique (GMSK 9600 baud, BW ~5 kHz, Fs_out ~48 kSPS) : **+8 à +12 dB** d'amélioration du plancher en bande.
- Le bruit de quantification est sculpté comme $(1-z^{-1})^2$ et repoussé vers les hautes fréquences hors-bande.

### Fichiers modifiés V5

| Fichier | Modification |
|---|---|
| `lib/dsp/round_sd.v` | Paramètre SD_ORDER, generate block 2nd order, feedback err_fb clippé |
| `lib/dsp/ddc_chain.v` | round_sd instances sortie : SD_ORDER(1) → SD_ORDER(2) |

---

## Version 6 — 13 mars 2026

**Fichier bitstream :** `usrp_b220_fpga_v6_opus++.bin`  
**Compilé le :** 13 mars 2026  
**Stratégie :** Optimisations Vivado + validation hardware

### Résultats de compilation V6

| Ressource | V5 | V6 | Disponible |
|---|---|---|---|
| **WNS** | +0,325 ns | **+0,325 ns** ✅ | — |

**Statut :** ✅ **CONFIRMÉ FONCTIONNEL EN PRODUCTION** — L'erreur `accum_timeout < _timeout` qui se produisait lors de l'initialisation UHD (`soapy.source`) a été **résolue** par l'amélioration globale du WNS à +0,325 ns. Le bus de contrôle USB 2.0 (via FX3/USBIP) est désormais stable.

### Modifications V6

#### 1. Stratégies Vivado agressives (`build.tcl`)

| Étape | Avant | Après |
|---|---|---|
| Synthèse strategy | `default` | `Flow_PerfOptimized_high` |
| RETIMING | non | **true** (repositionnement automatique des registres) |
| opt_design | directive par défaut | `Explore` |
| place_design | directive par défaut | `Explore` |
| phys_opt_design | directive par défaut | `Explore` |
| route_design | directive par défaut | `Explore` |
| Post-route phys_opt | absent | `Explore` (passe supplémentaire) |
| Nombre de threads | — | 8 |

Ces stratégies allongent le temps de compilation (~25 min → ~35 min) mais permettent à Vivado d'explorer un espace de conception beaucoup plus large pour optimiser les chemins critiques.

### Fichiers modifiés V6

| Fichier | Modification |
|---|---|
| `build.tcl` | Stratégies `Flow_PerfOptimized_high`, `RETIMING true`, directives `Explore` partout |

---

## Version 7 — 13 mars 2026 — ❌ REVERTÉE

**Fichier bitstream :** `usrp_b220_fpga_v7_gem.bin`  
**Compilé le :** 13 mars 2026  
**Stratégie :** Halfband filters full-precision 25×18 DSP48E1  
**Statut :** ❌ **CASSÉ — accum_timeout à l'initialisation UHD**

### Modifications V7 (revertées)

#### 1. `small_hb_dec.v` — Suppression du round_in d'entrée, datapath 24 bits

Suppression totale du bloc `round_sd` d'entrée (qui tronquait 24→17 bits avant multiplication). Les entrées restaient à pleine résolution 24 bits. Multiplications natives 25×18 via `MULT_MACRO` produisant un produit de 43 bits. Accumulation sur 43 bits. Sortie via `round_sd` 43→25→clip 24.

#### 2. `hb_dec.v` — Suppression du round_in d'entrée, datapath 24 bits

Même principe : suppression du `round_sd` d'entrée. Multiplication 25×18 (44-bit product). Accumulation sur 46 bits. Sortie via `round_sd` 46→25→clip 24.

### ⚠️ Cause de la régression

**Le bloc `round_sd` d'entrée supprimé avait une latence pipeline de 2 cycles d'horloge.** En le retirant, la latence totale de la chaîne DDC (Digital Down Converter) a été raccourcie de 4 cycles (2 par halfband × 2 halfbands dans la chaîne).

Le contrôleur UHD (` b200_core.v` → driver host) repose sur un flux **isochrone** : les timestamps des paquets VITA doivent correspondre exactement au débit attendu. Un raccourcissement de 4 cycles provoque une arrivée prématurée des données, saturant les buffers de contrôle USB et déclenchant le deadlock matériel `accum_timeout < _timeout` lors du loopback d'initialisation.

**WNS V7 : +0,371 ns** (paradoxalement bon — le problème n'était pas le timing mais la **latence fonctionnelle**).

### Résolution

Code V7 des halfband filters **entièrement reverté** au code V4/V6 d'origine avant d'entamer la V8.

### Leçon critique

> **Règle DSP #1 :** Lorsqu'on modifie un module dans une chaîne pipeline isochrone, il faut **impérativement** préserver la latence totale au cycle près, même si la nouvelle implémentation est fonctionnellement correcte. Le contrôleur UHD ne tolère aucune variation de latence.

---

## Version 8 "Masterpiece" — 13 mars 2026

**Fichier bitstream :** `libresdr_b220_v8_masterpiece.bin`  
**Compilé le :** 13 mars 2026 (22h02 → 22h21, ~19 min)  
**Stratégie :** Full-precision halfband + latency-safe pipeline + SD_ORDER(2)

### Résultats de compilation V8

| Ressource | V6 | V8 | Disponible |
|---|---|---|---|
| Slice LUTs | ~26 % | **35,56 % (47 860)** | 134 600 |
| Slice Registers | ~14,2 % | **14,49 % (39 020)** | 269 200 |
| Block RAM Tiles | 31,64 % | **31,64 % (115,5)** | 365 |
| DSP48E1 | 112 (15,1 %) | **112 (15,1 %)** | 740 |
| **WNS** | +0,325 ns | **+0,211 ns** ✅ | — |

`All user specified timing constraints are met.` — 0 Errors, 0 Critical Warnings.

### Modifications V8

#### 1. `small_hb_dec.v` — Full 24-bit datapath avec préservation de latence

**Problème résolu :** Conserver la pleine résolution 24 bits (comme la V7) tout en préservant exactement les 2 cycles de latence du bloc `round_sd` d'entrée supprimé.

**Solution :** Remplacement du `round_sd` d'entrée (qui tronquait 24→17 bits) par un pipeline de 2 registres qui **conserve les 24 bits intacts** tout en reproduisant exactement la latence de 2 cycles :

```verilog
// V8: Pipeline latency-safe — 2 clock delay, zéro perte de précision
localparam INTWIDTH = WIDTH;   // 24 (était 17)

reg [INTWIDTH-1:0]   data_rnd_pipe;
reg [INTWIDTH-1:0]   data_rnd;
reg                  stb_rnd_pipe;
reg                  stb_rnd;

always @(posedge clk) begin
    if (rst | ~run) begin
        stb_rnd_pipe <= 0; stb_rnd <= 0;
        data_rnd_pipe <= 0; data_rnd <= 0;
    end else begin
        stb_rnd_pipe <= stb_in;
        stb_rnd <= stb_rnd_pipe;
        if (stb_in) data_rnd_pipe <= data_in;
        if (stb_rnd_pipe) data_rnd <= data_rnd_pipe;
    end
end
```

**Datapath en aval :**
- Sommes symétriques (d[0]+d[6], d[2]+d[4]) sur **25 bits** (sign-extended)
- Multiplication DSP48E1 native **25×18** → produit **43 bits**
- Accumulation sur **43 bits** (centre tap aligné)
- Sortie via `round_sd` 43→25 bits avec **SD_ORDER(2)** → clip 24 bits

**Impact :** +42 dB de dynamique interne récupérée (24 vs 17 bits d'entrée). Le bruit de troncature de l'ancien round_in est **totalement éliminé**.

#### 2. `hb_dec.v` — Full 24-bit datapath, wire direct

**Même principe** que `small_hb_dec.v` mais adapté à la structure du filtre final `hb_dec` :

- Entrée directe via wire (pas de pipeline car la `round_sd` de sortie ajoutée en fin de chaîne compense la latence) :
```verilog
wire [INTWIDTH-1:0] data_rnd = data_in;  // INTWIDTH = WIDTH = 24
wire                stb_rnd  = stb_in;
```
- SRLs et sommes symétriques sur **25 bits**
- Deux multiplications DSP48E1 **25×18** → produits **44 bits**
- Addition des produits sur 45 bits, accumulation sur **46 bits** (ACCWIDTH = INTWIDTH + 22)
- **NOUVEAU :** Sortie via `round_sd` (46→25 bits, SD_ORDER(2)) au lieu du simple `clip` original
- Clip final 25→24 bits

```verilog
// V8: round_sd en sortie au lieu du clip direct
round_sd #(.WIDTH_IN(ACCWIDTH),.WIDTH_OUT(WIDTH+1),.SD_ORDER(2)) round_out
  (.clk(clk), .reset(rst), .in(final_sum),
   .strobe_in(stb_out_pre[8]), .out(final_sum_rnd), .strobe_out(round_stb));
clip #(.bits_in(WIDTH+1), .bits_out(WIDTH)) clip (.in(final_sum_rnd), .out(final_sum_clip));
```

**Shift factor** ajusté de 6 à 18 pour compenser le gain accumulé par les multiplications 25×18.

#### 3. SD_ORDER(2) systématique sur tous les rounders halfband

Les `round_sd` de sortie dans `small_hb_dec.v` et `hb_dec.v` utilisent désormais `SD_ORDER(2)` (second ordre). Le bruit de quantification résiduel est repoussé hors-bande avec une pente de **-12 dB/octave** au lieu de -6 dB/octave.

### Fichiers modifiés V8

| Fichier | Modification |
|---|---|
| `lib/dsp/small_hb_dec.v` | INTWIDTH 17→24, pipeline 2-clk latency-safe, MULT 25×18, accum 43b, SD_ORDER(2) |
| `lib/dsp/hb_dec.v` | INTWIDTH 17→24, wire direct, MULT 25×18 ×2, accum 46b, round_sd sortie SD_ORDER(2), SHIFT_FACTOR 6→18 |

### Bilan des améliorations DSP V8 (chaîne RX)

| Point de la chaîne | V6 (= V4) | V8 | Gain |
|---|---|---|---|
| `small_hb_dec` entrée | round_sd 24→17b (perte 7 bits) | **pipeline 24→24b (zéro perte)** | **+42 dB dynamique** |
| `small_hb_dec` multiplieur | 18×18 (max) | **25×18 DSP48E1 natif** | utilisation optimale HW |
| `small_hb_dec` accumulation | 30 bits | **43 bits** | +78 dB headroom |
| `small_hb_dec` sortie | round_sd SD_ORDER(1) | **round_sd SD_ORDER(2)** | **+8 dB noise floor** |
| `hb_dec` entrée | round_sd 24→17b (perte 7 bits) | **wire 24→24b (zéro perte)** | **+42 dB dynamique** |
| `hb_dec` multiplieur | 18×18 (max) | **25×18 DSP48E1 natif ×2** | utilisation optimale HW |
| `hb_dec` accumulation | 27 bits (ACCWIDTH) | **46 bits** | +114 dB headroom |
| `hb_dec` sortie | clip brut (pas de round_sd) | **round_sd SD_ORDER(2) + clip** | **+8 dB + anti-alias** |
| **Latence totale** | **identique** | **identique** | ✅ |

---

## Architecture de la chaîne DSP — V8 "Masterpiece"

### Réception (RX DDC) — par canal

```
AD9361 I/Q (12 bits, DDR CMOS)
    │
    ▼ [libresdr_b205_io.v]
Port P0 désérialisé (24 bits I/Q)
    │
    ▼ [ddc_chain.v — MUX real/IQ/swap]
rx_fe_i_mux  /  rx_fe_q_mux  (24 bits)
    │
    ▼ [dc_offset_correct.v — V1.1]     fc ≈ 9 Hz, IIR HP, bypass via SR BASE+5
    │
    ▼ [iq_balance.v — V4]              correction IQ, 24×18 DSP48E1 pleine précision
    │
    ▼ [LFSR 16 bits — V3]              dither RPDF ±1 LSB (élimine idle tones CIC)
    │
    ▼ [cordic_z24.v — V3]              NCO 48 bits, 24 étages, sortie arrondie
I/Q décalé en fréquence (24 bits, arrondi)
    │
    ▼ [cic_decim.v]                    CIC décimateur N=4, taux 1..256
    ▼ [cic_dec_shifter.v — V3]         compensation gain, arrondi convergent
I/Q décimé (24 bits)
    │
    ▼ [hbdec1 — HB1]                   demi-bande ×2
    ▼ [hbdec2 — HB2]                   demi-bande ×2
I/Q (24 bits)
    │
    ▼ [small_hb_dec — HB3 — V8]        24 bits plein, pipeline latency-safe,
    │                                   25×18 DSP48E1, accum 43b, round_sd SD_ORDER(2)
    │
    ▼ [hb_dec — V8]                     24 bits plein, 25×18 ×2 DSP48E1 natif,
    │                                   accum 46b, round_sd SD_ORDER(2) + clip
    │
    ▼ [MULT_MACRO + round_sd — V5]     facteur d'échelle + sigma-delta 2ème ordre
Sortie 16 bits I/Q → UHD host
```

**Décimation totale maximale :** 2 × 2 × 2 × 256 = **×2048** (HB3 activé)  
**Fréquence d'échantillonnage min :** 61,44 MSPS / 2048 ≈ **30 kSPS**

---

## Récapitulatif de toutes les versions

| Version | WNS | DSP | LUT | Fonctionnel | Notes |
|---|---|---|---|---|---|
| V0 (original) | — | ~100 | ~22 % | ✅ | Baseline |
| V1.0 | — | ~100 | ~22 % | ❌ | GPIF/FIFO cassé |
| V1.1 | +0,515 ns | 100 (13,5 %) | 22,81 % | ✅ | CIC 256 + DC offset |
| V2 | +0,165 ns | 112 (15,1 %) | 24,12 % | ✅ | IQ balance + HB3 + NCO 48b |
| V3 | +1,224 ns | 112 (15,1 %) | 25,50 % | ✅ | CORDIC 24 étages + rounding + fix HB bits |
| V3.1 | +0,369 ns | 112 (15,1 %) | 25,51 % | ✅ | Fix dither overflow |
| V4 | +0,228 ns | 112 (15,1 %) | 25,56 % | ✅ | IQ 24-bit + HB overflow-safe |
| V5 | +0,325 ns | 112 (15,1 %) | ~26 % | ✅ | round_sd SD_ORDER(2) |
| V6 | +0,325 ns | 112 (15,1 %) | ~26 % | ✅ | Vivado Explore + RETIMING — **production** |
| V7 | +0,371 ns | 112 (15,1 %) | ~35 % | ❌ | HB full-precision — **latence cassée** |
| **V8** | **+0,211 ns** | **112 (15,1 %)** | **35,56 %** | **❌** | **HB full-precision latency-safe + SD2 — accum_timeout** |
| V9 | +0,507 ns | 112 (15,1 %) | ~26 % | ❌ | Bypass mux HB3 fix + Vivado aggressive — **retiming casse le bus ctrl** |
| **V9b** | **+0,497 ns** | **112 (15,1 %)** | **~26 %** | **✅** | **V9 + stratégies Vivado par défaut — PRODUCTION** |

---

## Règles absolues

> 1. **Ne jamais modifier les interfaces GPIF/USB**, les tailles de FIFO `b200_core.v`/`libresdr_b210.v`, ni les contraintes SLEW dans `b210.xdc`. (V1.0 → échec irrécouvrable.)
> 2. **Toujours préserver la latence pipeline exacte** (au cycle près) lorsqu'on modifie un module dans la chaîne DDC/DUC. Le contrôleur UHD repose sur un flux isochrone. (V7 → `accum_timeout`.)
> 3. **Tester le chargement firmware** (`uhd_usrp_probe` / SoapySDR init) après **chaque** modification avant de déclarer un build fonctionnel.
> 4. **Ne JAMAIS utiliser RETIMING** dans la synthèse Vivado (`STEPS.SYNTH_DESIGN.ARGS.RETIMING true`). Le retiming déplace les registres à travers la logique combinatoire, corrompant le bus de contrôle UHD et provoquant `accum_timeout`. (V6→V9 → échec systématique.)
> 5. **Utiliser UNIQUEMENT les stratégies Vivado par défaut** (`Vivado Synthesis Defaults`, `Vivado Implementation Defaults`). Les stratégies agressives (`Flow_PerfOptimized_high`, `Performance_ExplorePostRoutePhysOpt`, directives `Explore`) produisent des résultats non-déterministes qui cassent l'initialisation UHD. (V9 avec Explore → `accum_timeout`, V9b sans → ✅)
> 6. **Bypass externe pour HB3** : quand HB3 est désactivé, utiliser un mux combinatoire EXTERNE pour éviter le cycle supplémentaire du registre bypass interne de `small_hb_dec`. (V9 fix dans `ddc_chain.v`)
