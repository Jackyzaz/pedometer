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
		in   TEMP, PINB			; TEMP <- Port B
		andi TEMP, 0b00001000	; Mask bit only PB3
		cpi  TEMP, 0b00001000	; Check if switch PB3 is enabled
		brne EndInt				; If not skip to End Interrupt
		; --- 3. If enabled check value from sensor
		rcall check_majority	; Check Majority from 3 sensors
		cpi   r24, 1            ; Check if 1 is majority
		brne  EndInt            ; Else jump to End Interrupt
		; --- 4. If 1 Majority Update Counter Value
		ldi  r24, 1				; r24 = 1
		ldi  r25, 0				; r25 = 0
		add  COUNTER_L, r24		; COUNTER_L = COUNTER_L + 1
		adc  COUNTER_H, r25		; COUNTER_H = COUNTER_H + carry
		; --- 5. Update Digits Value
		rcall UpdateDigits		; update digit
		rcall delay_500ms_with_display  ; delay prevent bouncing
		; --- 6. Clear PCIFR Flag prevent 
		ldi  TEMP, 0b00011111   ; Clear ALL PCI0 flag
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
	push r24
	push r25            
	in   TEMP, PINB     ; TEMP <= PB0-7
	ldi  r23, 3			; Set loop counter to 3 (have 3 sensors)  
	clr  r25            ; Clear Majority Counter
	clr	 r24
	count_loop:
		lsr TEMP		; Shift left bit to carry
		adc r25, r24	; add carry to r25
		dec r23			; decrement loop counter
		brne count_loop ; Check if not reach 3 times, continue loop
	cpi  r25, 2		; if counter >= 2 
	brsh is_true    ; then set true       
	ldi  r24, 0     ; else set 0
	rjmp end_check
	is_true:
		ldi  r24, 1         
	end_check:
		pop  r25
		pop  r24
		pop  r23
		pop  TEMP
		ret

;------------------------------------------------
; UpdateDigits: update by each digit 1-4
;------------------------------------------------
UpdateDigits:
    push TEMP
    push COUNTER_L
    push COUNTER_H
    push r23       
    push r24
    push r25
    ; --- 1. Check Mode Step/Meter
    sbrs MODE_FLAG, 0   ; if mode=0 (step) jump to start_bcd
    rjmp start_bcd

    ; --- 1.1. Meter Mode: Multiply with 6 (Assume 1 step = 0.6 Meter)
    mov r24, COUNTER_L	; r24 = COUNTER_L
    mov r25, COUNTER_H	; r25 = COUNTER_H
    ldi r23, 5          ; loop counter= 5
	mul_loop:
		add COUNTER_L, r24	; COUNTER_L = COUNTER_L + COUNTER_L
		adc COUNTER_H, r25	; COUNTER_H = COUNTER_H + COUNTER_H + carry
		dec r23				; decrement loop counter
		brne mul_loop		; jump if loop not finished

	start_bcd:				; Clear DIG1-4
		clr DIG4
		clr DIG3
		clr DIG2
		clr DIG1
	
	; --- Extract Thousands ---
	L4: ldi  r16, low(1000)	; Load low byte of 1000 into r16
		ldi  r23, high(1000); Load high byte of 1000 into r23
		cp   r17, r16		; Compare r17 (low byte) with low(1000)
		cpc  r18, r23		; Compare r18 (high byte) with high(1000) including carry
		brlo L3				; If value < 1000, jump to hundreds (L3)
		sub  r17, r16		; ElseSubtract 1000 low byte from r17
		sbc  r18, r23		; Subtract 1000 high byte from r18 with borrow
		inc  DIG4			; Increment thousands counter
		rjmp L4				; ; Repeat loop for next 1000

	; --- Extract Hundreds ---
	L3: ldi  r16, 100           ; Load 100 into r16
		cp   r17, r16           ; Compare r17 (low byte) with 100
		ldi  r23, 0             ; Load 0 into r23 for high byte comparison
		cpc  r18, r23           ; Compare r18 (high byte) with 0 including carry
		brlo L2                 ; If value < 100, jump to tens (L2)
		sub  r17, r16           ; Subtract 100 from r17
		sbc  r18, r23           ; Subtract borrow from r18
		inc  DIG3               ; Increment hundreds counter
		rjmp L3                 ; Repeat loop for next 100

    ; --- Extract Tens ---
	L2: ldi  r16, 10            ; Load 10 into r16
		cp   r17, r16           ; Compare r17 (low byte) with 10
		ldi  r23, 0             ; Load 0 into r23 for high byte comparison
		cpc  r18, r23           ; Compare r18 (high byte) with 0 including carry
		brlo L1                 ; If value < 10, jump to units (L1)
		sub  r17, r16           ; Subtract 10 from r17
		sbc  r18, r23           ; Subtract borrow from r18
		inc  DIG2               ; Increment tens counter
		rjmp L2                 ; Repeat loop for next 10

    ; --- Extract Units ---
	L1: mov  DIG1, r17          ; Remaining value in r17 is the units digit (0-9)

	pop  r25            
	pop  r24
	pop  r23
	pop  COUNTER_H
	pop  COUNTER_L
	pop  TEMP
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