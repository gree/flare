# Replica visibility baseline (WSTR-0)

End-to-end visibility = write SEND to first replica observation (upper bound of the probe
window), one monotonic clock; NOT commit-to-apply. Times in microseconds. CI kind numbers are
relative only. No tolerance is applied here. The Redis arms are NOT equivalent durability
profiles to flare (see bench/visibility/README.md); redis-mem is a latency reference only.

## Arms

| arm | floor GET RTT p50/p99 | validity |
|---|---|---|
| flare-floor | 178 / 297 | FLOOR CONTROL (write and read the master); master vis-bench-nodes-0 uid (some 2893133b-b3dc-46c8-a04d-0ff3d5ee7ed5)->(some 2893133b-b3dc-46c8-a04d-0ff3d5ee7ed5) boot (some 7693347401826452839)->(some 7693347401826452839); replica vis-bench-nodes-1 uid (some 0fb616e4-aa93-48f0-a660-3722577be897)->(some 0fb616e4-aa93-48f0-a660-3722577be897) boot (some 7693347444776125799)->(some 7693347444776125799); master cmd_get (some 0)->(some 63532); replica follow=(some 0) state=(some idle) |
| flare-hybrid-poll | 314 / 17012 | INVALID for replica visibility: 187740 GET(s) reached the master (proxied); master vis-bench-nodes-0 uid (some 2893133b-b3dc-46c8-a04d-0ff3d5ee7ed5)->(some 2893133b-b3dc-46c8-a04d-0ff3d5ee7ed5) boot (some 7693347401826452839)->(some 7693347401826452839); replica vis-bench-nodes-1 uid (some 0fb616e4-aa93-48f0-a660-3722577be897)->(some 0fb616e4-aa93-48f0-a660-3722577be897) boot (some 7693347444776125799)->(some 7693347444776125799); master cmd_get (some 63532)->(some 251272); replica follow=(some 1) state=(some following) |
| flare-legacy | 134 / 221 | VALID: every replica GET served locally (master cmd_get unchanged); master vis-bench-nodes-0 uid (some 2893133b-b3dc-46c8-a04d-0ff3d5ee7ed5)->(some 2893133b-b3dc-46c8-a04d-0ff3d5ee7ed5) boot (some 7693347401826452839)->(some 7693347401826452839); replica vis-bench-nodes-1 uid (some 0fb616e4-aa93-48f0-a660-3722577be897)->(some 0fb616e4-aa93-48f0-a660-3722577be897) boot (some 7693347444776125799)->(some 7693347444776125799); master cmd_get (some 63532)->(some 63532); replica follow=(some 0) state=(some idle) |
| redis-aof | 133 / 204 | VALID: replica linked, identities unchanged; profile aof (appendfsync no); before primary [redis_version:7.2.5 run_id:eb8e96d7e96799374db10edc91165bf442596343 role:master connected_slaves:1] replica [redis_version:7.2.5 run_id:edb0e820c582a71b0bd275dd475867583e7c022e role:slave master_link_status:up connected_slaves:0]; after primary [redis_version:7.2.5 run_id:eb8e96d7e96799374db10edc91165bf442596343 role:master connected_slaves:1] replica [redis_version:7.2.5 run_id:edb0e820c582a71b0bd275dd475867583e7c022e role:slave master_link_status:up connected_slaves:0] |
| redis-floor | 149 / 334 | FLOOR CONTROL (write and read the primary); profile aof (appendfsync no); before primary [redis_version:7.2.5 run_id:ff2ecd0e3362ca71fd4fee5e2f92b3f1631fe024 role:master connected_slaves:1] replica [redis_version:7.2.5 run_id:4fd558f0ce5c0ad9d1cf0fd401b69b51c07a04db role:slave master_link_status:up connected_slaves:0]; after primary [redis_version:7.2.5 run_id:ff2ecd0e3362ca71fd4fee5e2f92b3f1631fe024 role:master connected_slaves:1] replica [redis_version:7.2.5 run_id:4fd558f0ce5c0ad9d1cf0fd401b69b51c07a04db role:slave master_link_status:up connected_slaves:0] |
| redis-mem | 145 / 331 | VALID: replica linked, identities unchanged; profile mem (appendfsync n/a, no persistence); before primary [redis_version:7.2.5 run_id:01024a3ce80206d0872b43bf6e8517dccaaef2b4 role:master connected_slaves:1] replica [redis_version:7.2.5 run_id:77aa1aed0c90f1a32bb7213e086288720884f6c8 role:slave master_link_status:up connected_slaves:0]; after primary [redis_version:7.2.5 run_id:01024a3ce80206d0872b43bf6e8517dccaaef2b4 role:master connected_slaves:1] replica [redis_version:7.2.5 run_id:77aa1aed0c90f1a32bb7213e086288720884f6c8 role:slave master_link_status:up connected_slaves:0] |

## Results per profile and repeat

| arm | profile | rep | drained before (ms) | measured | visible | timeouts | vis p50 | vis p95 | vis p99 | vis max | vis-lower p99 | ack p99 | achieved/s | sched-lag p99 | backlog max | growing |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| flare-floor | idle | 0 | 1 | 100 | 100 | 0 | 533 | 660 | 889 | 1075 | 173 | 794 | 3 | 2065 | 1 | False |
| flare-floor | normal | 0 | 1 | 10000 | 10000 | 0 | 308 | 432 | 808 | 3667 | 77 | 628 | 500 | 1092 | 1 | False |
| flare-floor | peak | 0 | 1 | 40000 | 40000 | 0 | 1459905 | 2302762 | 2416816 | 2514663 | 0 | 87920 | 2000 | 1092 | 4479 | True |
| flare-hybrid-poll | idle | 0 | 1 | 100 | 100 | 0 | 716 | 20490 | 21572 | 34574 | 5954 | 20270 | 3 | 2091 | 1 | False |
| flare-hybrid-poll | idle | 1 | 9 | 100 | 100 | 0 | 657 | 1054 | 30073 | 46871 | 1 | 29802 | 3 | 2080 | 1 | False |
| flare-hybrid-poll | low | 0 | 1 | 2000 | 2000 | 0 | 636 | 22600 | 33831 | 70725 | 5080 | 23797 | 100 | 2093 | 4 | False |
| flare-hybrid-poll | low | 1 | 1 | 2000 | 2000 | 0 | 641 | 21336 | 33932 | 67386 | 9342 | 28903 | 100 | 2104 | 5 | False |
| flare-hybrid-poll | normal | 0 | 6 | 10000 | 10000 | 0 | 5342 | 43083 | 58942 | 90862 | 1704 | 42403 | 500 | 1117 | 37 | False |
| flare-hybrid-poll | normal | 1 | 1 | 10000 | 10000 | 0 | 6124 | 42689 | 56836 | 73929 | 1915 | 38979 | 500 | 1108 | 33 | False |
| flare-hybrid-poll | peak | 0 | 1 | 40000 | 20931 | 19069 | 4990778 | 5014649 | 5046612 | 5098099 | 0 | 109307 | 2000 | 1110 | 10146 | True |
| flare-hybrid-poll | peak | 1 | 1 | 40000 | 35397 | 4603 | 4527549 | 4997721 | 5010278 | 5058721 | 0 | 1169 | 2000 | 1092 | 10008 | True |
| flare-hybrid-poll | burst | 0 | 1 | 2000 | 2000 | 0 | 1411622 | 2236455 | 2335019 | 2406055 | 0 | 387907 | 75115 | 27068 | 2000 | None |
| flare-hybrid-poll | burst | 1 | 22 | 2000 | 2000 | 0 | 1544311 | 2538932 | 2641211 | 2671580 | 0 | 266870 | 69482 | 29743 | 2000 | None |
| flare-hybrid-poll | sat-4000 | 0 | 60 | 40000 | 8938 | 31062 | 4999337 | 5030518 | 5054717 | 5100142 | 0 | 3658106 | 4000 | 1115 | 20109 | True |
| flare-hybrid-poll | sat-4000 | 1 | 40 | 40000 | 8654 | 31346 | 4999214 | 5018973 | 5062998 | 5116826 | 0 | 3239120 | 4000 | 466150 | 20109 | True |
| flare-hybrid-poll | sat-8000 | 0 | 40 | 80000 | 112 | 79888 | 5000521 | 5053631 | 5063020 | 5063533 | 0 | 12747673 | 3490 | 12951011 | 39999 | False |
| flare-hybrid-poll | sat-8000 | 1 | 21 | 80000 | 2493 | 77507 | 4663632 | 4994100 | 5001644 | 5069732 | 0 | 11852477 | 2600 | 19233708 | 25405 | False |
| flare-legacy | idle | 0 | 1 | 100 | 100 | 0 | 807 | 1123 | 1536 | 1936 | 1051 | 1099 | 3 | 2115 | 1 | False |
| flare-legacy | idle | 1 | 51 | 100 | 100 | 0 | 758 | 916 | 1121 | 1149 | 495 | 753 | 3 | 1948 | 1 | False |
| flare-legacy | low | 0 | 1 | 2000 | 2000 | 0 | 584 | 953 | 1316 | 2440 | 753 | 737 | 100 | 2098 | 1 | False |
| flare-legacy | low | 1 | 1 | 2000 | 2000 | 0 | 597 | 977 | 1569 | 2779 | 788 | 765 | 100 | 2096 | 1 | False |
| flare-legacy | normal | 0 | 1 | 10000 | 10000 | 0 | 510 | 865 | 1434 | 6145 | 669 | 702 | 500 | 1093 | 1 | False |
| flare-legacy | normal | 1 | 1 | 10000 | 10000 | 0 | 496 | 838 | 1330 | 3955 | 611 | 717 | 500 | 1092 | 1 | False |
| flare-legacy | peak | 0 | 1 | 40000 | 40000 | 0 | 25373 | 68722 | 107053 | 194593 | 61402 | 1597 | 2000 | 1088 | 199 | False |
| flare-legacy | peak | 1 | 51 | 40000 | 40000 | 0 | 751982 | 1426374 | 1591283 | 1730480 | 1092192 | 1670 | 2000 | 1071 | 2316 | True |
| flare-legacy | burst | 0 | 51 | 2000 | 2000 | 0 | 898147 | 1187000 | 1191504 | 1192892 | 1084174 | 469936 | 68443 | 29421 | 2000 | None |
| flare-legacy | burst | 1 | 51 | 2000 | 2000 | 0 | 1074933 | 1377610 | 1399899 | 1401691 | 1365452 | 390079 | 59702 | 33623 | 2000 | None |
| flare-legacy | sat-4000 | 0 | 1 | 40000 | 0 | 40000 | - | - | - | - | - | 1538680 | 4000 | 1082 | 29393 | True |
| flare-legacy | sat-4000 | 1 | 9653 | 40000 | 0 | 40000 | - | - | - | - | - | 482288 | 4000 | 1083 | 30145 | True |
| flare-legacy | sat-8000 | 0 | 9480 | 80000 | 0 | 80000 | - | - | - | - | - | 5776236 | 4675 | 8185426 | 45087 | False |
| flare-legacy | sat-8000 | 1 | 24246 | 80000 | 0 | 80000 | - | - | - | - | - | 8568177 | 4278 | 7812944 | 52550 | False |
| redis-aof | idle | 0 | 0 | 100 | 100 | 0 | 592 | 915 | 1513 | 3141 | 400 | 1117 | 3 | 2117 | 1 | False |
| redis-aof | idle | 1 | 1 | 100 | 100 | 0 | 566 | 743 | 930 | 971 | 180 | 652 | 3 | 2039 | 1 | False |
| redis-aof | low | 0 | 0 | 2000 | 2000 | 0 | 450 | 773 | 1460 | 3303 | 215 | 1000 | 100 | 2111 | 1 | False |
| redis-aof | low | 1 | 0 | 2000 | 2000 | 0 | 436 | 795 | 1726 | 3756 | 213 | 899 | 100 | 2126 | 1 | False |
| redis-aof | normal | 0 | 0 | 10000 | 10000 | 0 | 302 | 651 | 1265 | 4754 | 197 | 787 | 500 | 1114 | 1 | False |
| redis-aof | normal | 1 | 0 | 10000 | 10000 | 0 | 292 | 532 | 835 | 4719 | 103 | 541 | 500 | 1110 | 2 | False |
| redis-aof | peak | 0 | 0 | 40000 | 40000 | 0 | 422 | 821 | 1854 | 5766 | 369 | 1216 | 2000 | 1094 | 7 | False |
| redis-aof | peak | 1 | 0 | 40000 | 40000 | 0 | 292 | 590 | 1380 | 4768 | 412 | 950 | 2000 | 1091 | 5 | False |
| redis-aof | burst | 0 | 0 | 2000 | 2000 | 0 | 64180 | 88309 | 90780 | 91414 | 0 | 42231 | 51503 | 38857 | 2000 | None |
| redis-aof | burst | 1 | 0 | 2000 | 2000 | 0 | 51868 | 90008 | 92752 | 93510 | 0 | 28584 | 73352 | 27319 | 2000 | None |
| redis-aof | sat-4000 | 0 | 0 | 40000 | 40000 | 0 | 384 | 958 | 2400 | 8851 | 833 | 1536 | 4000 | 1098 | 10 | False |
| redis-aof | sat-4000 | 1 | 0 | 40000 | 40000 | 0 | 377 | 986 | 2160 | 5380 | 681 | 1258 | 4000 | 1096 | 16 | False |
| redis-aof | sat-8000 | 0 | 0 | 80000 | 80000 | 0 | 371 | 2517 | 7032 | 12691 | 216 | 1605 | 8000 | 547 | 188 | False |
| redis-aof | sat-8000 | 1 | 0 | 80000 | 80000 | 0 | 366 | 1452 | 3361 | 8022 | 183 | 1122 | 8000 | 371 | 52 | False |
| redis-floor | idle | 0 | 1 | 100 | 100 | 0 | 418 | 533 | 934 | 1108 | 0 | 699 | 3 | 1876 | 0 | False |
| redis-floor | normal | 0 | 0 | 10000 | 10000 | 0 | 268 | 487 | 710 | 4601 | 0 | 666 | 500 | 1122 | 2 | False |
| redis-floor | peak | 0 | 0 | 40000 | 40000 | 0 | 448 | 874 | 1328 | 6544 | 0 | 1169 | 2000 | 1115 | 4 | False |
| redis-mem | idle | 0 | 1 | 100 | 100 | 0 | 435 | 626 | 1119 | 1279 | 155 | 470 | 3 | 2435 | 1 | False |
| redis-mem | idle | 1 | 0 | 100 | 100 | 0 | 421 | 615 | 657 | 898 | 154 | 703 | 3 | 1989 | 0 | False |
| redis-mem | low | 0 | 0 | 2000 | 2000 | 0 | 273 | 522 | 710 | 2270 | 109 | 509 | 100 | 2088 | 1 | False |
| redis-mem | low | 1 | 0 | 2000 | 2000 | 0 | 277 | 528 | 870 | 2253 | 111 | 508 | 100 | 2093 | 1 | False |
| redis-mem | normal | 0 | 0 | 10000 | 10000 | 0 | 238 | 491 | 838 | 3663 | 96 | 527 | 500 | 1093 | 2 | False |
| redis-mem | normal | 1 | 0 | 10000 | 10000 | 0 | 237 | 482 | 752 | 3399 | 95 | 492 | 500 | 1100 | 1 | False |
| redis-mem | peak | 0 | 1 | 40000 | 40000 | 0 | 406 | 824 | 1905 | 5238 | 351 | 1205 | 2000 | 1095 | 6 | False |
| redis-mem | peak | 1 | 0 | 40000 | 40000 | 0 | 274 | 448 | 1119 | 6404 | 240 | 741 | 2000 | 1082 | 3 | False |
| redis-mem | burst | 0 | 0 | 2000 | 2000 | 0 | 77613 | 115335 | 118065 | 118706 | 0 | 37727 | 55698 | 35784 | 2000 | None |
| redis-mem | burst | 1 | 0 | 2000 | 2000 | 0 | 84962 | 117076 | 119967 | 120653 | 0 | 32943 | 68416 | 29889 | 2000 | None |
| redis-mem | sat-4000 | 0 | 0 | 40000 | 40000 | 0 | 371 | 824 | 1877 | 5595 | 440 | 1074 | 4000 | 1099 | 8 | False |
| redis-mem | sat-4000 | 1 | 0 | 40000 | 40000 | 0 | 369 | 896 | 1981 | 5048 | 453 | 1147 | 4000 | 1095 | 11 | False |
| redis-mem | sat-8000 | 0 | 0 | 80000 | 80000 | 0 | 342 | 2692 | 7953 | 21970 | 166 | 1428 | 8000 | 461 | 54 | False |
| redis-mem | sat-8000 | 1 | 0 | 80000 | 80000 | 0 | 344 | 2098 | 5805 | 12646 | 206 | 1340 | 8000 | 415 | 42 | False |

## Deltas vs redis-aof (worst repeat per profile; flare − redis, and ratio)

| arm | profile | p95 Δ µs | p95 ratio | p99 Δ µs | p99 ratio | ack p99 Δ µs |
|---|---|---|---|---|---|---|
| flare-hybrid-poll | idle | 19575 | 22.40 | 28560 | 19.87 | 28685 |
| flare-hybrid-poll | low | 21805 | 28.44 | 32206 | 19.66 | 27903 |
| flare-hybrid-poll | normal | 42432 | 66.13 | 57677 | 46.60 | 41616 |
| flare-hybrid-poll | peak | 5013829 | 6110.63 | 5044758 | 2721.57 | 108091 |
| flare-hybrid-poll | burst | 2448925 | 28.21 | 2548459 | 28.48 | 345676 |
| flare-hybrid-poll | sat-4000 | 5029532 | 5101.87 | 5060598 | 2110.02 | 3656570 |
| flare-hybrid-poll | sat-8000 | 5051115 | 2008.16 | 5055988 | 719.99 | 12746068 |
| flare-legacy | idle | 208 | 1.23 | 23 | 1.02 | -18 |
| flare-legacy | low | 182 | 1.23 | -157 | 0.91 | -234 |
| flare-legacy | normal | 213 | 1.33 | 169 | 1.13 | -70 |
| flare-legacy | peak | 1425553 | 1738.12 | 1589429 | 858.16 | 455 |
| flare-legacy | burst | 1287602 | 15.31 | 1307147 | 15.09 | 427705 |
| flare-legacy | sat-4000 | - | - | - | - | 1537144 |
| flare-legacy | sat-8000 | - | - | - | - | 8566572 |
| redis-mem | idle | -289 | 0.68 | -394 | 0.74 | -414 |
| redis-mem | low | -267 | 0.66 | -856 | 0.50 | -491 |
| redis-mem | normal | -161 | 0.75 | -427 | 0.66 | -260 |
| redis-mem | peak | 3 | 1.00 | 51 | 1.03 | -11 |
| redis-mem | burst | 27068 | 1.30 | 27215 | 1.29 | -4504 |
| redis-mem | sat-4000 | -90 | 0.91 | -419 | 0.83 | -389 |
| redis-mem | sat-8000 | 176 | 1.07 | 921 | 1.13 | -177 |
