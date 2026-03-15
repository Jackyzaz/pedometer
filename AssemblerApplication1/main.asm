.include "m328pdef.inc"

.def MODE_FLAG = r15 ; Display Mode 0 = Step, 1 = Meter
.def TEMP      = r16

; 16 bit counter by use 2 register R18:R17
.def COUNTER_L = r17  
.def COUNTER_H = r18 

; 4 BCD register
.def DIG1      = r19 
.def DIG2      = r20 
.def DIG3      = r21 
.def DIG4      = r22 

.cseg
.org 0x0000
    rjmp start
.org 0x0006
    rjmp PinChangeInt0 

start:
    ; 1. Set stack pointer to last address
    ldi TEMP, low(RAMEND)
    out SPL, TEMP
    ldi TEMP, high(RAMEND)
    out SPH, TEMP

    ; 2. Set Output Port D (Segments) and Port C (Digits Multiplex)
    ldi TEMP, 0b11111111   
    out DDRD, TEMP      
    ldi TEMP, 0b00001111 
    out DDRC, TEMP      

    ; 3. Allow Interrupt PCI0 (Port B)
    ldi r20, 0x01           ; Set PCICR first bit to allow PCI0
    ldi ZL, low(PCICR)		; load low address to ZL
    ldi ZH, high(PCICR)		; load high address to ZH
    st  Z, r20				; store by memory address

    ; --- Allow PB 0-4 to use interrupt PCMSK0 ---
    ldi r20, 0b00011111		; config mask PB0 1 2 3 4
    ldi ZL, low(PCMSK0)		; load low address to ZL
    ldi ZH, high(PCMSK0)	; load high address to ZH
    st  Z, r20				; Store by memory address

    ; 4. Set input direction Port B
    ldi TEMP, 0b11100000	; Input PB 01234
    out DDRB, TEMP		

    ; 5. Clear Status
    clr COUNTER_L			; Clear Low Counter to 0
    clr COUNTER_H			; Clear High Counter to 0
    clr MODE_FLAG			; Set Mode flag to counter mode

	; 6. Start 7 Segment Display
    rcall UpdateDigits			
	sei

main_loop:
	rcall display_counter
	rjmp main_loop

display_counter:
    push TEMP
    push r25

    ; --- Show Digit 1
    mov  r25, DIG1			; Load BCD 1
    rcall BIN_TO_7SEG		; convert bcd to 7seg
    out  PORTD, r25			; send 7seg display
    ldi  TEMP, 0b00000001	; Turn on digit 1
    out  PORTC, TEMP		; send digit multiplex
    rcall delay_1ms			

    ; --- Show Digit 2
    mov  r25, DIG2			; Load BCD 2
    rcall BIN_TO_7SEG		; convert bcd to 7seg
    ; Check Meter Mode logic
    sbrc MODE_FLAG, 0		; skip next instruction if not use meter mode
	ori  r25, 0b10000000    ; if true, turn on dp (dot) segment
    out  PORTD, r25			; send 7seg display
    ldi  TEMP, 0b00000010	; Turn on digit 2
    out  PORTC, TEMP		; send digit multiplex
    rcall delay_1ms

    ; --- Show Digit 3
    mov  r25, DIG3			; Load BCD 3
    rcall BIN_TO_7SEG		; convert bcd to 7seg
    out  PORTD, r25			; send 7seg display
    ldi  TEMP, 0b00000100	; Turn on digit 3
    out  PORTC, TEMP		; send digit multiplex
    rcall delay_1ms

    ; --- Show Digit 4
    mov  r25, DIG4			; Load BCD 3
    rcall BIN_TO_7SEG		; convert bcd to 7seg
    out  PORTD, r25			; send 7seg display
    ldi  TEMP, 0b00001000	; Turn on digit 4
    out  PORTC, TEMP		; send digit multiplex
    rcall delay_1ms

    pop r25
    pop TEMP
    ret

;------------------------------------------------
; Interrupt Handler for PCI0
;------------------------------------------------
PinChangeInt0:
    push TEMP
    in   TEMP, SREG
    push TEMP
    push r24
    push r25
    push r26

    ; --- 1. Check Mode Button is press
    in   TEMP, PINB          ; TEMP <- Port B
    sbrs TEMP, 4             ; Skip if bit PB4 is logic high
    rjmp check_step          ; Else go to check step
    ldi  r24, 1				 ; r24 = 1
    eor  MODE_FLAG, r24      ; MODE_FLAG = 1 (means its is meter mode)
    rcall UpdateDigits       ; Update Digit as Meter Unit
    rjmp EndInt              ; End ISR

	check_step:
		; --- 2. Check Counter Switch is Enable
		in   TEMP, PINB
		andi TEMP, 0b00001000  ; Check PB03
		cpi  TEMP, 0b00001000  ; Check if PB03 enabled
		brne EndInt            ; If not skip to end Interrupt

		; Check Majority from 3 sensors
		rcall check_majority
		cpi   r24, 1            ; ดูว่าผลลัพธ์เป็น 1 (Majority High) หรือไม่
		brne  EndInt            ; ถ้าไม่ใช่ ให้กระโดดไปจบ Interrupt ทันที

		; --- ส่วนนับก้าว (ทำงานเมื่อเป็นเสียงส่วนใหญ่เท่านั้น) ---
		ldi  r24, 1          
		ldi  r25, 0          
		add  COUNTER_L, r24  
		adc  COUNTER_H, r25  

		rcall UpdateDigits  
		rcall delay_500ms_with_display  

		; ล้าง Flag เพื่อป้องกันการเด้งซ้ำจาก Noise
		ldi  TEMP, 0b00011111   ; *** แก้ครอบคลุม Flag PB4 ด้วย ***
		out  PCIFR, TEMP      

	EndInt:
		pop  r26
		pop  r25
		pop  r24
		pop  TEMP
		out  SREG, TEMP
		pop  TEMP
		reti

	;------------------------------------------------
	; Subroutine: check_majority check from PB0-2
	; r25 -> Marjority Coutner
	; R23 -> Loop Counter
	; TEMP -> Input reader
	;------------------------------------------------
	check_majority:
		push TEMP
		push r23
		push r25            
		in   TEMP, PINB     ; TEMP <= xxxxx:PB0:PB:1PB2
		ldi  r23, 3			; Set loop Counter to 3 (have 3 sensors)  
		clr  r25            ; Clear Majority Counter
		count_loop:
			lsr  TEMP		; Shift left bit to carry
			brcc skip_inc	
			inc  r25
			skip_inc:
				dec  r23
				brne count_loop ; Check if not reach 3 times, continue loop
		cpi  r25, 2		; if counter >= 2 
		brsh is_true    ; then set true       
		ldi  r24, 0     ; else set 0
		rjmp end_check
		is_true:
			ldi  r24, 1         
		end_check:
			pop  r25
			pop  r23
			pop  TEMP
			ret



;------------------------------------------------
; อัปเดตตัวเลขแยกหลัก
;------------------------------------------------
UpdateDigits:
    push r16
    push r17
    push r18
    push r23            ; *** push เพิ่มสำหรับใช้คูณ ***
    push r24
    push r25

    mov r17, COUNTER_L
    mov r18, COUNTER_H

    ; *** ตรวจสอบโหมด ***
    sbrs MODE_FLAG, 0   ; ถ้าโหมดก้าว (0) ให้ข้ามไปแยกหลัก BCD เลย
    rjmp start_bcd

    ; โหมดเมตร: คูณจำนวนก้าวด้วย 7 (1 ก้าว = 0.6 เมตร)
    mov r24, r17
    mov r25, r18
    ldi r23, 5          ; นำมาบวกทบกัน 5 ครั้ง (รวมตัวมันเอง = 6)
	mul_loop:
		add r17, r24
		adc r18, r25
		dec r23
		brne mul_loop

	start_bcd:
		clr DIG4
		clr DIG3
		clr DIG2
		clr DIG1

	L4: ldi  r16, low(1000)
		ldi  r23, high(1000)
		cp   r17, r16
		cpc  r18, r23
		brlo L3
		sub  r17, r16
		sbc  r18, r23
		inc  DIG4
		rjmp L4

	L3: ldi  r16, 100
		cp   r17, r16
		ldi  r23, 0
		cpc  r18, r23
		brlo L2
		sub  r17, r16
		sbc  r18, r23
		inc  DIG3
		rjmp L3

	L2: ldi  r16, 10
		cp   r17, r16
		ldi  r23, 0
		cpc  r18, r23
		brlo L1
		sub  r17, r16
		sbc  r18, r23
		inc  DIG2
		rjmp L2

	L1: mov  DIG1, r17
		pop  r25            ; *** pop คืนให้ครบ ***
		pop  r24
		pop  r23
		pop  r18
		pop  r17
		pop  r16
		ret
;------------------------------------------------
; Delay Subroutine
;------------------------------------------------
delay_500ms_with_display:
    ldi  r26, 50				; Loop 50 time
	d_step1:
		push r26				; 2 clk cycle
		rcall display_counter	; 4ms (While doing delay also run refresh digit)
		pop  r26				; 2 clk cycle
		dec  r26				; 1 clk cycle
		brne d_step1			; 1 clk cyle
		ret

delay_1ms:
	push r24
	push r23

    ldi  r24, 20
d1: ldi  r23, 255
d2: dec  r23
    brne d2
    dec  r24
    brne d1
    
	pop r23
	pop r24
	ret


;------------------------------------------------
; Binary (BCD) to 7 Segment
; r25 is both input and output
;------------------------------------------------
BIN_TO_7SEG:
    push ZL
    push ZH
    push r0
	
	clr r0
	rjmp LOOK_TABLE		; call table
	
	TB_7SEG:
		.DB 0b00111111, 0b00000110	; 0, 1
		.DB 0b01011011, 0b01001111	; 2, 3
		.DB 0b01100110, 0b01101101	; 4, 5
		.DB 0b01111101, 0b00000111	; 6, 7
		.DB 0b01111111, 0b01101111	; 8, 9

	LOOK_TABLE:
		ldi ZL, low(TB_7SEG*2)	; set lower address of TB_7SEG to ZL
		ldi ZH, high(TB_7SEG*2)	; set higher address of TB_7SEG to ZH
		add ZL, r25				; ZL <- ZL + r25 
		adc ZH, r0				; ZH <- ZH + r0 + carry
		lpm r0, Z				; load program memmory Z to r0
		mov r25, r0				; z25 <- r0
    
	pop r0
	pop ZH
	pop ZL
	ret