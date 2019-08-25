; laputa-os
; TAB=4
; FILE: 启动程序装载器

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; 常量声明
CYLS    EQU     10  ; 读取柱面个数
MAX_SCT  EQU     18  ; 一个柱面18个扇区

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; 如遇到特殊地址先参考：https://wiki.osdev.org/Memory_Map_(x86)

    ORG 0x7c00      ; 指定启动区内容装载地址(地址偏移)

; 标准FAT12格式(软盘专用格式) 【固定】
    JMP entry
    NOP             ; 这两行原来是 DB 0xeb, 0x4e, 0x90（0x90=NOP，0xeb 0x4e=JMP 0x7c50）
    DB "LAPUTA  "   ; 厂商名称(启动区名称,8字节)
    DW 512          ; 扇区大小(字节)
    DB 1            ; 簇大小(扇区)
    DW 1            ; FAT表起始位置（保留扇区数/Boot信息所占扇区数）
    DB 2            ; FAT表个数(2)
    DW 224          ; 根目录文件最大个数(224)
    DW 2880         ; 磁盘大小(2880扇区)
    DB 0xf0         ; 磁盘种类(0xf0)
    DW 9            ; 单个FAT表长度(扇区)
    DW 18           ; 1个磁道的扇区数
    DW 2            ; 磁头数2
    DD 0            ; 隐藏扇区数(0)
    DD 2880         ; 磁盘大小重复一次
    ;（文件系统总扇区数，当上面表示磁盘大小的值为0时这里生效，区别是字节数不同）
    DB 0, 0, 0x29       ; 中断13的驱动器号, 未使用, 扩展引导标记(0x29)
    DD 0xffffffff       ; 磁盘卷序列号
    DB "LAPUTA-OS  "    ; 磁盘名称
    DB "FAT12   "      ; 文件系统类型
    ;上面一共62字节，空出18字节到达偏移80（0x50），原因：参考上面JMP（0x7c00+0x50）
    RESB 18
    ; 接下来是引导代码

    ; 正式代码
entry:
    ; 初始化
    MOV AX, 0
    MOV SS, AX          ; 从AX赋值原因是立即数并不快于从寄存器中取值
    MOV SP, 0x7c00
    MOV DS, AX
    
    ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    ; AH: 0x02:读盘，0x03:写盘，0x04:校验，0x0c:寻道
    ; CHS地址:柱面（0~1023）-磁头（0~15）-扇区（1~63）
    ; (软盘80个柱面*2个磁头*18个扇区)
    ;
    ; AL:处理扇区数，0为非法，不能跨越ES页边界或柱面边界，并且必须<128
    ; CH:柱面号 & 0xff
    ; CL:扇区号 | ((柱面号 >> 2) & 0xC0)
    ; DH:磁头号
    ; ES:BX -> 缓冲地址
    ; DL:驱动器号
    ; INT 0x13.
    ; 发生错误则设置进位标志. 成功则会将AH重设置为0
    ; 参考：https://wiki.osdev.org/ATA_in_x86_RealMode_(BIOS)
    ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    ; 这里注意控制扇区号和柱面号的寄存器赋值
    ; 因为柱面号最大是79（0x4f），所以CH=柱面号
    ; 同样，0xC0只有高2位是1，而柱面号不超过1字节，右移2位后高两位是0，所以
    ; ((柱面号 >> 2) & 0xC0) 始终为0，所以CL=扇区号
    ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
    
    
bios_read_disk:    
    ; 读磁盘C0H0S2（IPL位于第二个扇区）
    MOV AX, 0x0820
    MOV ES, AX          ; 为了将数据加载到[ES:BX]的位置
    ; 这里ES的值是自定义的，实际可用内存在0x7e00-0x7ffff
    MOV CH, 0           ; C
    MOV DH, 0           ; H
    MOV CL, 2           ; S
    
__brd_loop:
    MOV SI, 0           ; 失败次数
__brd_retry:
    MOV AH, 0x02
    MOV AL, 1           ; 读1个扇区
                        ;（为了不跨柱面读，每次一个扇区最好？）
    MOV BX, 0           ; [ES:BX]使用
    MOV DL, 0x00        ; 驱动器号
    INT 0x13
    JNC next            ; 不出错就读下一扇区
    ADD SI, 1           ; 错误数+1
    CMP SI, 5
    JAE error           ; if SI >= 5 JMP error
    MOV AH, 0x00
    MOV DL, 0x00
    INT 0x13            ; 重置磁盘控制器
    JMP __brd_retry
next:
    MOV AX, ES
    ADD AX, 0x0020
    MOV ES, AX          ; 相当于ADD ES, 0x0020，一个扇区512字节，512/16=0x20，相当于扇区+1
    ADD CL, 1           ; c+1，扇区号
    CMP	CL, MAX_SCT     ; 一个柱面18个扇区
    JBE __brd_loop      ; 柱面正/反面未读完，继续读
    MOV CL, 1           ; 柱面正/反面读完了，扇区重置为1
    ADD DH, 1           ;切换磁头（读反面、正面）
    CMP DH, 2
    JB  __brd_loop      ; 切换到反面了
    MOV DH, 0           ; 已经在反面了，所以要柱面+1，磁头置0
    ADD CH, 1
    CMP CH, CYLS
    JB  __brd_loop      ; 没读CYLS个柱面，继续读
    
    ; 已经在内存中装了CYLS个柱面数据（512*18*2*CYLS=）184,320(0x2d000)字节
    ; 位置是0x8200 - 0x34fff（总共10个柱面，但是少了一个扇区，因为我们从柱面0磁头0的2号扇区开始读的）

fin:
    HLT
    JMP fin
    
error:
	MOV SI, msg
print:
    MOV AL, [SI]
    ADD SI, 1
    CMP AL, 0
    JE  fin
    MOV AH, 0x0e
    MOV BX, 15
    INT 0x10
    JMP print

msg:
    DB 0x0a, 0x0a
    DB "Load disk data error."
    DB 0x0a
    DB 0

    RESB	0x7dfe-$
    ; 启动引导扇区必须以0xAA55结尾，这里通过计算中间补空白

    DB		0x55, 0xaa


