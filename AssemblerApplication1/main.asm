.include "m328pdef.inc"

.def MODE_FLAG = r15 ; โหมดการแสดงผล: 0 = นับก้าว (Step), 1 = ระยะทาง (Meter)
.def TEMP      = r16

; ตัวนับขนาด 16 บิต โดยใช้รีจิสเตอร์คู่ R18:R17
.def COUNTER_L = r17  
.def COUNTER_H = r18 

; รีจิสเตอร์สำหรับเก็บค่า BCD ทั้ง 4 หลัก
.def DIG1      = r19 
.def DIG2      = r20 
.def DIG3      = r21 
.def DIG4      = r22 

.cseg
.org 0x0000
    rjmp start
.org 0x0006
    rjmp PinChangeInt0 ; อินเตอร์รัพท์เมื่อมีการเปลี่ยนสถานะพิน (PCI0)

start:
    ; 1. ตั้งค่า Stack Pointer ไปที่ตำแหน่งสุดท้ายของ RAM
    ldi TEMP, low(RAMEND)
    out SPL, TEMP
    ldi TEMP, high(RAMEND)
    out SPH, TEMP

    ; 2. ตั้งค่าพอร์ต: Port D เป็น Output (Segment), Port C เป็น Output (Digit Multiplex)
    ldi TEMP, 0b11111111   
    out DDRD, TEMP      
    ldi TEMP, 0b00001111 
    out DDRC, TEMP      

    ; 3. เปิดใช้งานอินเตอร์รัพท์ PCI0 (กลุ่ม Port B)
    ldi r20, 0x01             ; ตั้งค่าบิตแรกของ PCICR เพื่อเปิดใช้งาน PCI0
    ldi ZL, low(PCICR)        ; โหลดตำแหน่ง Address ต่ำของ PCICR เข้า ZL
    ldi ZH, high(PCICR)       ; โหลดตำแหน่ง Address สูงของ PCICR เข้า ZH
    st  Z, r20                ; จัดเก็บค่าลงในหน่วยความจำ

    ; --- กำหนดให้ PB 0-4 สามารถสร้างอินเตอร์รัพท์ได้ผ่าน PCMSK0 ---
    ldi r20, 0b00011111        ; เลือกพิน PB0, 1, 2, 3, 4
    ldi ZL, low(PCMSK0)        
    ldi ZH, high(PCMSK0)    
    st  Z, r20                

    ; 4. ตั้งค่า Port B ให้เป็น Input (PB 0-4)
    ldi TEMP, 0b11100000    
    out DDRB, TEMP        

    ; 5. ล้างสถานะเริ่มต้น
    clr COUNTER_L             ; ล้างค่าตัวนับตัวต่ำเป็น 0
    clr COUNTER_H             ; ล้างค่าตัวนับตัวสูงเป็น 0
    clr MODE_FLAG             ; เริ่มต้นที่โหมดนับก้าว (Step mode)

    ; 6. เริ่มการแสดงผล 7 Segment
    rcall UpdateDigits        ; อัปเดตค่าตัวเลขที่จะแสดง     
    sei                       ; เปิดการใช้งานอินเตอร์รัพท์รวม (Global Interrupt)

main_loop:
    rcall display_counter     ; เรียกฟังก์ชันแสดงผลตัวเลข
    rjmp main_loop            ; วนลูปการทำงานหลัก

display_counter:
    push TEMP
    push r25

    ; --- แสดงผลหลักที่ 1
    mov  r25, DIG1            ; โหลดค่า BCD หลักที่ 1
    rcall BIN_TO_7SEG         ; แปลง BCD เป็นรหัส 7 Segment
    out  PORTD, r25           ; ส่งข้อมูลออกทาง Port D
    ldi  TEMP, 0b00000001     ; เปิดการทำงานหลักที่ 1
    out  PORTC, TEMP          ; เลือกหลักผ่าน Port C
    rcall delay_1ms           ; หน่วงเวลาเพื่อให้ตามองทัน

    ; --- แสดงผลหลักที่ 2
    mov  r25, DIG2            ; โหลดค่า BCD หลักที่ 2
    rcall BIN_TO_7SEG         
    ; ตรวจสอบตรรกะโหมดระยะทาง (Meter Mode)
    sbrc MODE_FLAG, 0         ; ถ้าไม่ใช่โหมด Meter ให้ข้ามคำสั่งถัดไป
    ori  r25, 0b10000000      ; ถ้าใช่ ให้เปิดจุดทศนิยม (DP) ที่หลักนี้
    out  PORTD, r25           
    ldi  TEMP, 0b00000010     ; เปิดการทำงานหลักที่ 2
    out  PORTC, TEMP          
    rcall delay_1ms

    ; --- แสดงผลหลักที่ 3
    mov  r25, DIG3            
    rcall BIN_TO_7SEG         
    out  PORTD, r25           
    ldi  TEMP, 0b00000100     ; เปิดการทำงานหลักที่ 3
    out  PORTC, TEMP          
    rcall delay_1ms

    ; --- แสดงผลหลักที่ 4
    mov  r25, DIG4            
    rcall BIN_TO_7SEG         
    out  PORTD, r25           
    ldi  TEMP, 0b00001000     ; เปิดการทำงานหลักที่ 4
    out  PORTC, TEMP          
    rcall delay_1ms

    pop r25
    pop TEMP
    ret

;------------------------------------------------
; ส่วนจัดการอินเตอร์รัพท์ (Interrupt Handler) สำหรับ PCI0
;------------------------------------------------
PinChangeInt0:
    push TEMP
    in   TEMP, SREG           ; เก็บค่าสถานะ Register (SREG)
    push TEMP
    push r24
    push r25
    push r26

    ; --- 1. ตรวจสอบว่าปุ่มเปลี่ยนโหมดถูกกดหรือไม่ (PB4)
    in   TEMP, PINB          
    sbrs TEMP, 4              ; ข้ามถ้าพิน PB4 เป็น High (ไม่ได้กดแบบ Active Low)
    rjmp check_step           ; ถ้ากด ให้ไปตรวจสอบการนับก้าวต่อ
    ldi  r24, 1               
    eor  MODE_FLAG, r24       ; สลับโหมด (0 เป็น 1 หรือ 1 เป็น 0)
    rcall UpdateDigits        ; อัปเดตตัวเลขตามโหมดที่เปลี่ยน
    rjmp EndInt               ; จบการทำงานอินเตอร์รัพท์

    check_step:
        ; --- 2. ตรวจสอบว่าสวิตช์ตัวนับถูกเปิดอยู่หรือไม่ (PB3)
        in   TEMP, PINB          
        andi TEMP, 0b00001000    ; ตรวจสอบเฉพาะบิต PB3
        cpi  TEMP, 0b00001000    ; เช็คว่าเป็น High หรือไม่
        brne EndInt              ; ถ้าปิดอยู่ ให้ข้ามไปจบอินเตอร์รัพท์

        ; --- 3. ตรวจสอบค่าจากเซนเซอร์ (ใช้หลักการเสียงข้างมาก)
        rcall check_majority     ; ตรวจสอบสัญญาณจากเซนเซอร์ 3 ตัว
        cpi   r24, 1             ; เช็คว่าผลลัพธ์ส่วนใหญ่เป็น 1 หรือไม่
        brne  EndInt             ; ถ้าไม่ใช่ ให้ข้ามไปจบอินเตอร์รัพท์

        ; --- 4. อัปเดตค่าตัวนับเมื่อสัญญาณถูกต้อง
        ldi  r24, 1                
        ldi  r25, 0                
        add  COUNTER_L, r24       ; บวกค่าตัวต่ำเพิ่ม 1
        adc  COUNTER_H, r25       ; บวกค่าตัวสูงพร้อมตัวทด (Carry)

        ; --- 5. อัปเดตตัวเลขที่จะแสดงผล
        rcall UpdateDigits        
        rcall delay_500ms_with_display ; หน่วงเวลาเพื่อป้องกันการสั่นของสวิตช์ (Debouncing)

        ; --- 6. ล้าง Flag อินเตอร์รัพท์เพื่อป้องกันการซ้อนทับ
        ldi  TEMP, 0b00011111   
        out  PCIFR, TEMP      

    EndInt:
        pop  r26
        pop  r25
        pop  r24
        pop  TEMP
        out  SREG, TEMP        ; คืนค่าสถานะ Register
        pop  TEMP
        reti

;------------------------------------------------
; Subroutine: check_majority ตรวจสอบสัญญาณจาก PB0-2
; r24 -> ผลลัพธ์ (1 = จริง, 0 = เท็จ)
; r25 -> ตัวนับจำนวนที่เป็นบิต 1
; r23 -> ตัวนับรอบลูป
;------------------------------------------------
check_majority:
    push TEMP
    push r23
    push r25                
    in   TEMP, PINB      ; อ่านค่าจาก Port B
    ldi  r23, 3          ; ตั้งรอบลูป 3 ครั้ง (สำหรับเซนเซอร์ 3 ตัว)  
    clr  r25             ; ล้างตัวนับบิต High
    clr  r24             ; ล้างค่าคงที่สำหรับใช้บวก
    
    count_loop:
        lsr TEMP         ; เลื่อนบิตขวาเข้า Carry Flag
        adc r25, r24     ; ถ้า Carry=1 ให้บวกเข้า r25
        dec r23          
        brne count_loop  ; วนจนครบ 3 บิต
    
    cpi  r25, 2          ; ถ้ามีสัญญาณ High ตั้งแต่ 2 ตัวขึ้นไป
    brsh is_true         ; ให้ถือว่าเป็นสัญญาณจริง
    ldi  r24, 0          ; ถ้าไม่ถึง ให้เป็น 0
    rjmp end_check
    
    is_true:
        ldi  r24, 1          
    
    end_check:
        pop  r25
        pop  r23
        pop  TEMP
        ret

;------------------------------------------------
; UpdateDigits: แยกค่าตัวเลข 16 บิต ออกเป็นหลักหน่วย/สิบ/ร้อย/พัน
;------------------------------------------------
UpdateDigits:
    push TEMP
    push COUNTER_L
    push COUNTER_H
    push r23       
    push r24
    push r25
    
    ; --- 1. ตรวจสอบโหมด Step หรือ Meter
    sbrs MODE_FLAG, 0   ; ถ้า mode=0 (Step) ให้ข้ามไปเริ่มแปลง BCD เลย
    rjmp start_bcd

    ; --- 1.1 โหมด Meter: คูณด้วย 6 (สมมติ 1 ก้าว = 0.6 เมตร)
    mov r24, COUNTER_L    
    mov r25, COUNTER_H    
    ldi r23, 5          ; วนลูปบวกเพิ่ม 5 ครั้ง (เพื่อให้รวมของเดิมเป็น 6 เท่า)
    mul_loop:
        add COUNTER_L, r24    
        adc COUNTER_H, r25    
        dec r23                
        brne mul_loop        

    start_bcd:                ; ล้างค่าหลักตัวเลขทั้ง 4 ก่อนเริ่มคำนวณ
        clr DIG4
        clr DIG3
        clr DIG2
        clr DIG1
    
    ; --- แยกหลักพัน ---
    L4: ldi  r16, low(1000)   
        ldi  r23, high(1000)
        cp   r17, r16        
        cpc  r18, r23        
        brlo L3               ; ถ้าค่าน้อยกว่า 1000 ให้ไปคำนวณหลักร้อย
        sub  r17, r16        
        sbc  r18, r23        
        inc  DIG4             ; เพิ่มค่าหลักพัน
        rjmp L4               

    ; --- แยกหลักร้อย ---
    L3: ldi  r16, 100          
        cp   r17, r16           
        ldi  r23, 0             
        cpc  r18, r23           
        brlo L2               ; ถ้าค่าน้อยกว่า 100 ให้ไปคำนวณหลักสิบ
        sub  r17, r16           
        sbc  r18, r23           
        inc  DIG3             
        rjmp L3                 

    ; --- แยกหลักสิบ ---
    L2: ldi  r16, 10            
        cp   r17, r16           
        ldi  r23, 0             
        cpc  r18, r23           
        brlo L1               ; ถ้าค่าน้อยกว่า 10 ให้ไปคำนวณหลักหน่วย
        sub  r17, r16           
        sbc  r18, r23           
        inc  DIG2             
        rjmp L2                 

    ; --- แยกหลักหน่วย ---
    L1: mov  DIG1, r17          ; ค่าที่เหลืออยู่ใน r17 คือหลักหน่วย

    pop  r25            
    pop  r24
    pop  r23
    pop  COUNTER_H
    pop  COUNTER_L
    pop  TEMP
    ret

;------------------------------------------------
; ฟังก์ชันหน่วงเวลา (สำหรับ CPU 16 MHz)
;------------------------------------------------
delay_500ms_with_display:
    push r26
    ldi  r26, 50              ; วนรอบ 50 ครั้ง
    d_step1:
        push r26                
        rcall display_counter ; ในขณะหน่วงเวลา ให้เรียกแสดงผลไปด้วยเพื่อไม่ให้ไฟดับ
        pop  r26                
        dec  r26                
        brne d_step1            
    pop r26
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
; แปลงค่าตัวเลข (BCD) เป็นรหัสสำหรับ 7 Segment
; r25 เป็นทั้ง Input (ตัวเลข 0-9) และ Output
;------------------------------------------------
BIN_TO_7SEG:
    push ZL
    push ZH
    push r0
    clr r0
    rjmp LOOK_TABLE        ; ข้ามส่วนข้อมูลไปยังส่วนดึงค่า
    TB_7SEG:
        .DB 0b00111111, 0b00000110    ; เลข 0, 1
        .DB 0b01011011, 0b01001111    ; เลข 2, 3
        .DB 0b01100110, 0b01101101    ; เลข 4, 5
        .DB 0b01111101, 0b00000111    ; เลข 6, 7
        .DB 0b01111111, 0b01101111    ; เลข 8, 9
    LOOK_TABLE:
        ldi ZL, low(TB_7SEG*2)    ; ชี้ไปที่ตำแหน่งเริ่มต้นของตารางข้อมูล
        ldi ZH, high(TB_7SEG*2)    
        add ZL, r25               ; บวกค่าตัวเลขเพื่อเลื่อนไปยังตำแหน่งรหัสที่ต้องการ
        adc ZH, r0                ; บวกตัวทด
        lpm r0, Z                 ; โหลดข้อมูลจาก Program Memory เข้า r0
        mov r25, r0               ; คืนค่ารหัสที่ได้กลับทาง r25
    pop r0
    pop ZH
    pop ZL
    ret