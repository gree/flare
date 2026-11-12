# Replica visibility baseline (WSTR-0)

End-to-end visibility = write SEND to first replica observation (upper bound of the probe
window), one monotonic clock; NOT commit-to-apply. Times in microseconds. CI kind numbers are
relative only. No tolerance is applied here. The Redis arms are NOT equivalent durability
profiles to flare (see bench/visibility/README.md); redis-mem is a latency reference only.

## Arms

| arm | floor GET RTT p50/p99 | validity |
|---|---|---|
| flare-floor | 153 / 273 | FLOOR CONTROL (write and read the master); master vis-bench-nodes-0 uid (some c58549ce-3dd2-4134-bb79-150fdc4549aa)->(some c58549ce-3dd2-4134-bb79-150fdc4549aa) boot (some 7693330552669750631)->(some 7693330552669750631); replica vis-bench-nodes-1 uid (some 87c1cfdc-6fd5-44d0-b71d-3dbe23d9686a)->(some 87c1cfdc-6fd5-44d0-b71d-3dbe23d9686a) boot (some 7693330591324456295)->(some 7693330591324456295); master cmd_get (some 0)->(some 63698); replica follow=(some 0) state=(some idle) |
| flare-hybrid-poll | 302 / 1527 | INVALID for replica visibility: 174495 GET(s) reached the master (proxied); master vis-bench-nodes-0 uid (some c58549ce-3dd2-4134-bb79-150fdc4549aa)->(some c58549ce-3dd2-4134-bb79-150fdc4549aa) boot (some 7693330552669750631)->(some 7693330552669750631); replica vis-bench-nodes-1 uid (some 87c1cfdc-6fd5-44d0-b71d-3dbe23d9686a)->(some 87c1cfdc-6fd5-44d0-b71d-3dbe23d9686a) boot (some 7693330591324456295)->(some 7693330591324456295); master cmd_get (some 63698)->(some 238193); replica follow=(some 1) state=(some following) |
| flare-legacy | 136 / 228 | VALID: every replica GET served locally (master cmd_get unchanged); master vis-bench-nodes-0 uid (some c58549ce-3dd2-4134-bb79-150fdc4549aa)->(some c58549ce-3dd2-4134-bb79-150fdc4549aa) boot (some 7693330552669750631)->(some 7693330552669750631); replica vis-bench-nodes-1 uid (some 87c1cfdc-6fd5-44d0-b71d-3dbe23d9686a)->(some 87c1cfdc-6fd5-44d0-b71d-3dbe23d9686a) boot (some 7693330591324456295)->(some 7693330591324456295); master cmd_get (some 63698)->(some 63698); replica follow=(some 0) state=(some idle) |
| redis-aof | 134 / 240 | VALID: replica linked, identities unchanged; profile aof (appendfsync no); before primary [redis_version:7.2.5 run_id:8eac3872db3d256f1b0cbc5ce5d1239a9ac03452 role:master connected_slaves:1] replica [redis_version:7.2.5 run_id:cb9bbe4fdeeb23aa96e4506e05e95efb6c44ed01 role:slave master_link_status:up connected_slaves:0]; after primary [redis_version:7.2.5 run_id:8eac3872db3d256f1b0cbc5ce5d1239a9ac03452 role:master connected_slaves:1] replica [redis_version:7.2.5 run_id:cb9bbe4fdeeb23aa96e4506e05e95efb6c44ed01 role:slave master_link_status:up connected_slaves:0] |
| redis-floor | 151 / 260 | FLOOR CONTROL (write and read the primary); profile aof (appendfsync no); before primary [redis_version:7.2.5 run_id:eaec79d6f4602ee0a74f3be6d4db218402c0199c role:master connected_slaves:1] replica [redis_version:7.2.5 run_id:b61c80f4be0016a7c8bc85e3bb5cfd372386d16b role:slave master_link_status:up connected_slaves:0]; after primary [redis_version:7.2.5 run_id:eaec79d6f4602ee0a74f3be6d4db218402c0199c role:master connected_slaves:1] replica [redis_version:7.2.5 run_id:b61c80f4be0016a7c8bc85e3bb5cfd372386d16b role:slave master_link_status:up connected_slaves:0] |
| redis-mem | 138 / 197 | VALID: replica linked, identities unchanged; profile mem (appendfsync n/a, no persistence); before primary [redis_version:7.2.5 run_id:c3433f7e63f6516fcc73223f2c57bdd323a00187 role:master connected_slaves:1] replica [redis_version:7.2.5 run_id:671d2ef4763ea051a5790a23bb6a0755f2156ee5 role:slave master_link_status:up connected_slaves:0]; after primary [redis_version:7.2.5 run_id:c3433f7e63f6516fcc73223f2c57bdd323a00187 role:master connected_slaves:1] replica [redis_version:7.2.5 run_id:671d2ef4763ea051a5790a23bb6a0755f2156ee5 role:slave master_link_status:up connected_slaves:0] |

## Results per profile and repeat

| arm | profile | rep | measured | visible | timeouts | vis p50 | vis p95 | vis p99 | vis max | vis-lower p99 | ack p99 | achieved/s | sched-lag p99 | backlog max | growing |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| flare-floor | idle | 0 | 100 | 100 | 0 | 646 | 804 | 1010 | 1317 | 203 | 1045 | 3 | 2037 | 0 | False |
| flare-floor | normal | 0 | 10000 | 10000 | 0 | 333 | 485 | 885 | 2613 | 78 | 662 | 500 | 1096 | 1 | False |
| flare-floor | peak | 0 | 40000 | 40000 | 0 | 1950770 | 3468818 | 3816722 | 3889602 | 0 | 75757 | 2000 | 1094 | 6552 | True |
| flare-hybrid-poll | idle | 0 | 100 | 100 | 0 | 1160 | 7344 | 8998 | 53240 | 6213 | 7616 | 3 | 1830 | 1 | False |
| flare-hybrid-poll | idle | 1 | 100 | 100 | 0 | 48454 | 57427 | 58188 | 59870 | 1698 | 57363 | 3 | 1982 | 1 | False |
| flare-hybrid-poll | low | 0 | 2000 | 2000 | 0 | 825 | 22866 | 30258 | 78714 | 10708 | 27336 | 100 | 2156 | 7 | False |
| flare-hybrid-poll | low | 1 | 2000 | 2000 | 0 | 543 | 26565 | 45273 | 68465 | 11947 | 27745 | 100 | 2083 | 5 | False |
| flare-hybrid-poll | normal | 0 | 10000 | 10000 | 0 | 2765 | 30316 | 49907 | 93009 | 2286 | 31739 | 500 | 1112 | 42 | False |
| flare-hybrid-poll | normal | 1 | 10000 | 10000 | 0 | 4541 | 35076 | 60563 | 80453 | 2187 | 32849 | 500 | 1106 | 36 | False |
| flare-hybrid-poll | peak | 0 | 40000 | 20279 | 19721 | 4992666 | 5017534 | 5046654 | 5070101 | 0 | 109510 | 2000 | 1119 | 10138 | False |
| flare-hybrid-poll | peak | 1 | 40000 | 25646 | 14354 | 4982259 | 5001454 | 5037620 | 5087591 | 0 | 118776 | 2000 | 1098 | 10123 | True |
| flare-hybrid-poll | burst | 0 | 2000 | 2000 | 0 | 1109798 | 1619964 | 1713338 | 1720198 | 0 | 917350 | 181840 | 11133 | 2000 | None |
| flare-hybrid-poll | burst | 1 | 2000 | 2000 | 0 | 914599 | 1423081 | 1506746 | 1511160 | 0 | 414231 | 74699 | 26916 | 2000 | None |
| flare-hybrid-poll | sat-4000 | 0 | 40000 | 6748 | 33252 | 4998053 | 5013774 | 5076988 | 5083662 | 0 | 5691699 | 3479 | 1638889 | 20111 | True |
| flare-hybrid-poll | sat-4000 | 1 | 40000 | 8666 | 31334 | 4999633 | 5035683 | 5059829 | 5090731 | 0 | 2894641 | 4000 | 1102 | 20142 | True |
| flare-hybrid-poll | sat-8000 | 0 | 80000 | 74 | 79926 | 4885976 | 5025346 | 5060506 | 5061763 | 0 | 10955012 | 3172 | 19231413 | 25515 | False |
| flare-hybrid-poll | sat-8000 | 1 | 80000 | 1303 | 78697 | 4636255 | 4983137 | 5001851 | 5077856 | 0 | 8537557 | 3385 | 15049740 | 31894 | False |
| flare-legacy | idle | 0 | 100 | 100 | 0 | 855 | 1081 | 1213 | 1631 | 570 | 1010 | 3 | 2130 | 0 | False |
| flare-legacy | idle | 1 | 100 | 0 | 100 | - | - | - | - | - | 2456 | 3 | 1175 | 17 | False |
| flare-legacy | low | 0 | 2000 | 2000 | 0 | 569 | 975 | 1668 | 2949 | 734 | 908 | 100 | 2087 | 1 | False |
| flare-legacy | low | 1 | 2000 | 779 | 1221 | 1142643 | 4603918 | 4927266 | 5023934 | 4855548 | 1910 | 100 | 2076 | 513 | False |
| flare-legacy | normal | 0 | 10000 | 10000 | 0 | 513 | 834 | 1503 | 22255 | 631 | 716 | 500 | 1093 | 6 | False |
| flare-legacy | normal | 1 | 10000 | 10000 | 0 | 494 | 770 | 1457 | 4399 | 745 | 622 | 500 | 1094 | 1 | False |
| flare-legacy | peak | 0 | 40000 | 40000 | 0 | 28293 | 65801 | 82797 | 141972 | 52434 | 1641 | 2000 | 1092 | 175 | False |
| flare-legacy | peak | 1 | 40000 | 40000 | 0 | 710224 | 1665777 | 1899186 | 2138394 | 1338570 | 1236 | 2000 | 1083 | 2834 | True |
| flare-legacy | burst | 0 | 2000 | 2000 | 0 | 1107709 | 1389127 | 1395034 | 1397208 | 1308117 | 456096 | 62143 | 32738 | 2000 | None |
| flare-legacy | burst | 1 | 2000 | 2000 | 0 | 708275 | 1072994 | 1150539 | 1151887 | 1058761 | 485171 | 49207 | 40717 | 2000 | None |
| flare-legacy | sat-4000 | 0 | 40000 | 0 | 40000 | - | - | - | - | - | 1647544 | 4000 | 1085 | 28906 | True |
| flare-legacy | sat-4000 | 1 | 40000 | 0 | 40000 | - | - | - | - | - | 3603383 | 3936 | 272530 | 29243 | True |
| flare-legacy | sat-8000 | 0 | 80000 | 0 | 80000 | - | - | - | - | - | 8435553 | 3944 | 9978597 | 32234 | False |
| flare-legacy | sat-8000 | 1 | 80000 | 0 | 80000 | - | - | - | - | - | 8060739 | 3514 | 14098597 | 34050 | False |
| redis-aof | idle | 0 | 100 | 100 | 0 | 699 | 1205 | 2430 | 7590 | 743 | 1237 | 3 | 1278 | 1 | False |
| redis-aof | idle | 1 | 100 | 100 | 0 | 526 | 1136 | 1989 | 2858 | 807 | 1189 | 3 | 1804 | 0 | False |
| redis-aof | low | 0 | 2000 | 2000 | 0 | 368 | 666 | 1419 | 2710 | 146 | 883 | 100 | 2106 | 1 | False |
| redis-aof | low | 1 | 2000 | 2000 | 0 | 303 | 576 | 1224 | 2658 | 143 | 569 | 100 | 2094 | 1 | False |
| redis-aof | normal | 0 | 10000 | 10000 | 0 | 294 | 615 | 1270 | 4520 | 112 | 709 | 500 | 1106 | 2 | False |
| redis-aof | normal | 1 | 10000 | 10000 | 0 | 257 | 429 | 717 | 4598 | 101 | 426 | 500 | 1099 | 1 | False |
| redis-aof | peak | 0 | 40000 | 40000 | 0 | 450 | 1188 | 2580 | 9654 | 788 | 1792 | 2000 | 1102 | 7 | False |
| redis-aof | peak | 1 | 40000 | 40000 | 0 | 304 | 661 | 1655 | 5254 | 470 | 1068 | 2000 | 1093 | 6 | False |
| redis-aof | burst | 0 | 2000 | 2000 | 0 | 76227 | 100132 | 101902 | 112452 | 0 | 44672 | 48548 | 41132 | 2000 | None |
| redis-aof | burst | 1 | 2000 | 2000 | 0 | 61278 | 79327 | 80722 | 81248 | 0 | 42495 | 50682 | 39279 | 2000 | None |
| redis-aof | sat-4000 | 0 | 40000 | 40000 | 0 | 390 | 1227 | 2386 | 5815 | 699 | 1345 | 4000 | 1102 | 14 | False |
| redis-aof | sat-4000 | 1 | 40000 | 40000 | 0 | 383 | 868 | 2145 | 8008 | 403 | 1225 | 4000 | 1097 | 11 | False |
| redis-aof | sat-8000 | 0 | 80000 | 80000 | 0 | 418 | 6037 | 13597 | 23155 | 202 | 2017 | 8000 | 660 | 152 | False |
| redis-aof | sat-8000 | 1 | 80000 | 80000 | 0 | 393 | 3024 | 5419 | 8433 | 259 | 1798 | 8000 | 449 | 26 | False |
| redis-floor | idle | 0 | 100 | 100 | 0 | 583 | 867 | 1539 | 1787 | 0 | 1526 | 3 | 2203 | 0 | False |
| redis-floor | normal | 0 | 10000 | 10000 | 0 | 284 | 505 | 794 | 13331 | 0 | 706 | 500 | 1114 | 2 | False |
| redis-floor | peak | 0 | 40000 | 40000 | 0 | 449 | 792 | 1299 | 5489 | 0 | 1108 | 2000 | 1110 | 9 | False |
| redis-mem | idle | 0 | 100 | 100 | 0 | 510 | 766 | 937 | 1235 | 443 | 677 | 3 | 2110 | 1 | False |
| redis-mem | idle | 1 | 100 | 100 | 0 | 424 | 588 | 958 | 1219 | 211 | 700 | 3 | 1945 | 0 | False |
| redis-mem | low | 0 | 2000 | 2000 | 0 | 339 | 649 | 1024 | 4109 | 158 | 653 | 100 | 2117 | 1 | False |
| redis-mem | low | 1 | 2000 | 2000 | 0 | 246 | 480 | 734 | 2464 | 157 | 536 | 100 | 2100 | 1 | False |
| redis-mem | normal | 0 | 10000 | 10000 | 0 | 260 | 518 | 818 | 5906 | 100 | 518 | 500 | 1098 | 1 | False |
| redis-mem | normal | 1 | 10000 | 10000 | 0 | 195 | 404 | 632 | 3922 | 103 | 412 | 500 | 1103 | 1 | False |
| redis-mem | peak | 0 | 40000 | 40000 | 0 | 423 | 764 | 1790 | 8312 | 204 | 1080 | 2000 | 1099 | 7 | False |
| redis-mem | peak | 1 | 40000 | 40000 | 0 | 302 | 713 | 2231 | 7935 | 808 | 1416 | 2000 | 1093 | 9 | False |
| redis-mem | burst | 0 | 2000 | 2000 | 0 | 58573 | 92296 | 94340 | 94841 | 0 | 32305 | 65703 | 30757 | 2000 | None |
| redis-mem | burst | 1 | 2000 | 2000 | 0 | 57628 | 95418 | 96371 | 96724 | 0 | 31562 | 66725 | 30704 | 2000 | None |
| redis-mem | sat-4000 | 0 | 40000 | 40000 | 0 | 371 | 820 | 1759 | 6630 | 341 | 1026 | 4000 | 1098 | 8 | False |
| redis-mem | sat-4000 | 1 | 40000 | 40000 | 0 | 374 | 881 | 2027 | 6043 | 405 | 1146 | 4000 | 1099 | 10 | False |
| redis-mem | sat-8000 | 0 | 80000 | 80000 | 0 | 331 | 2623 | 5882 | 11150 | 207 | 1647 | 8000 | 479 | 130 | False |
| redis-mem | sat-8000 | 1 | 80000 | 80000 | 0 | 348 | 2317 | 8220 | 18368 | 173 | 1370 | 8000 | 396 | 131 | False |

## Deltas vs redis-aof (worst repeat per profile; flare − redis, and ratio)

| arm | profile | p95 Δ µs | p95 ratio | p99 Δ µs | p99 ratio | ack p99 Δ µs |
|---|---|---|---|---|---|---|
| flare-hybrid-poll | idle | 56222 | 47.67 | 55758 | 23.94 | 56126 |
| flare-hybrid-poll | low | 25899 | 39.88 | 43855 | 31.91 | 26862 |
| flare-hybrid-poll | normal | 34460 | 57.02 | 59293 | 47.69 | 32140 |
| flare-hybrid-poll | peak | 5016346 | 4223.90 | 5044074 | 1955.93 | 116984 |
| flare-hybrid-poll | burst | 1519832 | 16.18 | 1611436 | 16.81 | 872678 |
| flare-hybrid-poll | sat-4000 | 5034455 | 4102.64 | 5074602 | 2127.71 | 5690354 |
| flare-hybrid-poll | sat-8000 | 5019309 | 832.45 | 5046909 | 372.17 | 10952995 |
| flare-legacy | idle | -124 | 0.90 | -1217 | 0.50 | 1219 |
| flare-legacy | low | 4603251 | 6910.56 | 4925847 | 3472.58 | 1027 |
| flare-legacy | normal | 219 | 1.36 | 233 | 1.18 | 7 |
| flare-legacy | peak | 1664590 | 1402.30 | 1896606 | 736.07 | -151 |
| flare-legacy | burst | 1288995 | 13.87 | 1293132 | 13.69 | 440499 |
| flare-legacy | sat-4000 | - | - | - | - | 3602038 |
| flare-legacy | sat-8000 | - | - | - | - | 8433536 |
| redis-mem | idle | -438 | 0.64 | -1472 | 0.39 | -537 |
| redis-mem | low | -17 | 0.97 | -395 | 0.72 | -230 |
| redis-mem | normal | -97 | 0.84 | -452 | 0.64 | -191 |
| redis-mem | peak | -424 | 0.64 | -349 | 0.86 | -375 |
| redis-mem | burst | -4714 | 0.95 | -5531 | 0.95 | -12367 |
| redis-mem | sat-4000 | -346 | 0.72 | -359 | 0.85 | -199 |
| redis-mem | sat-8000 | -3414 | 0.43 | -5377 | 0.60 | -370 |
